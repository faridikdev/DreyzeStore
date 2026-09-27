import Foundation

public struct APIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(configuration: APIConfiguration, session: URLSession = .shared) {
        self.baseURL = configuration.baseURL
        self.session = session
    }

    public func apps(page: Int = 1, limit: Int = 24, category: String? = nil, repository: String? = nil, sort: CatalogSort = .name) async throws -> AppsPage {
        var query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "sort", value: sort.rawValue)]
        if let category { query.append(URLQueryItem(name: "category", value: category)) }
        if let repository { query.append(URLQueryItem(name: "repository", value: repository)) }
        return try await getEnvelope("apps", query: query, as: [StoreApp].self).asPage()
    }

    public func categories() async throws -> [StoreCategory] {
        try await get("categories", as: [StoreCategory].self)
    }

    public func featured() async throws -> [FeaturedSection] {
        try await get("featured", as: [FeaturedSection].self)
    }

    public func search(_ term: String, page: Int = 1, limit: Int = 24) async throws -> AppsPage {
        var query = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit))]
        // The backend defaults to name sorting. Keep the request contract explicit.
        query.append(URLQueryItem(name: "sort", value: CatalogSort.name.rawValue))
        return try await getEnvelope("search", query: query, as: [StoreApp].self).asPage()
    }

    public func app(id: String) async throws -> StoreApp {
        try await get("apps/\(Self.pathComponent(id))", as: StoreApp.self)
    }

    public func versions(appID: String) async throws -> [AppVersion] {
        try await get("apps/\(Self.pathComponent(appID))/versions", as: [AppVersion].self)
    }

    public func updates(for installed: [InstalledVersion]) async throws -> [UpdateAvailable] {
        guard installed.count <= 25 else { throw StoreError.invalidRequest }
        let body = try JSONEncoder().encode(installed.map { ["bundleIdentifier": $0.bundleIdentifier, "installedVersion": $0.installedVersion] })
        guard let json = String(data: body, encoding: .utf8) else { throw StoreError.invalidRequest }
        return try await get("updates", query: [URLQueryItem(name: "apps", value: json)], as: [UpdateAvailable].self, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    public func repositoryManifest() async throws -> RepositoryManifest {
        try await request("repository", query: [], envelope: false, as: RepositoryManifest.self)
    }

    public func get<Value: Decodable & Sendable>(_ path: String, as type: Value.Type = Value.self) async throws -> Value {
        try await get(path, query: [], as: type)
    }

    private func get<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem], as type: Value.Type, cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Value {
        try await request(path, query: query, envelope: true, as: type, cachePolicy: cachePolicy)
    }

    private func getEnvelope<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem], as type: Value.Type) async throws -> APIEnvelope<Value> {
        let data = try await fetch(path, query: query)
        do { return try JSONDecoder.dreyzeStore.decode(APIEnvelope<Value>.self, from: data) }
        catch { throw StoreError.decodingFailure }
    }

    private func request<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem], envelope: Bool, as type: Value.Type, cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Value {
        let data = try await fetch(path, query: query, cachePolicy: cachePolicy)
        do {
            if envelope { return try JSONDecoder.dreyzeStore.decode(APIEnvelope<Value>.self, from: data).data }
            return try JSONDecoder.dreyzeStore.decode(Value.self, from: data)
        } catch { throw StoreError.decodingFailure }
    }

    private func fetch(_ path: String, query: [URLQueryItem], cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Data {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              let relative = URLComponents(string: path),
              relative.scheme == nil, relative.host == nil, relative.user == nil, relative.password == nil,
              relative.fragment == nil,
              !relative.percentEncodedPath.isEmpty,
              !relative.percentEncodedPath.hasPrefix("/"),
              !relative.percentEncodedPath.split(separator: "/").contains(where: Self.isTraversalSegment) else {
            throw StoreError.invalidRequest
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        components?.percentEncodedPath = "\(basePath)/\(relative.percentEncodedPath)"
        components?.queryItems = query
        guard let url = components?.url, url.host == baseURL.host, url.scheme == baseURL.scheme, url.path.hasPrefix(basePath + "/") else {
            throw StoreError.invalidRequest
        }

        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw StoreError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw StoreError.serverFailure(statusCode: http.statusCode) }
            return data
        } catch let error as StoreError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw StoreError.networkUnavailable
        }
    }

    private static func isTraversalSegment(_ segment: Substring) -> Bool {
        guard let decoded = String(segment).removingPercentEncoding else { return true }
        return decoded == "." || decoded == ".."
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? ""
    }
}

private extension APIEnvelope where Value == [StoreApp] {
    func asPage() -> AppsPage {
        let pageMetadata = meta.map {
            PageMetadata(
                requestId: $0.requestId,
                page: $0.page,
                pageSize: $0.pageSize,
                hasMore: $0.hasMore,
                nextCursor: $0.nextCursor
            )
        }
        return AppsPage(data: data, meta: pageMetadata)
    }
}

private extension JSONDecoder {
    static var dreyzeStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date.")
        }
        return decoder
    }
}
