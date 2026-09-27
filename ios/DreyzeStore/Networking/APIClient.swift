import Foundation

public struct APIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(configuration: APIConfiguration, session: URLSession = .shared) {
        self.baseURL = configuration.baseURL
        self.session = session
    }

    public func get<Value: Decodable & Sendable>(
        _ path: String,
        as type: Value.Type = Value.self
    ) async throws -> Value {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              let relative = URLComponents(string: path),
              relative.scheme == nil,
              relative.host == nil,
              relative.user == nil,
              relative.password == nil,
              relative.fragment == nil,
              !relative.percentEncodedPath.isEmpty,
              !relative.percentEncodedPath.hasPrefix("/"),
              !relative.percentEncodedPath.split(separator: "/").contains(where: Self.isTraversalSegment) else {
            throw StoreError.invalidRequest
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        components?.percentEncodedPath = "\(basePath)/\(relative.percentEncodedPath)"
        components?.percentEncodedQuery = relative.percentEncodedQuery
        guard let url = components?.url,
              url.host == baseURL.host,
              url.scheme == baseURL.scheme,
              url.path.hasPrefix(basePath + "/") else {
            throw StoreError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StoreError.networkUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StoreError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw StoreError.serverFailure(statusCode: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder.dreyzeStore.decode(APIEnvelope<Value>.self, from: data).data
        } catch {
            throw StoreError.decodingFailure
        }
    }

    private static func isTraversalSegment(_ segment: Substring) -> Bool {
        guard let decoded = String(segment).removingPercentEncoding else { return true }
        return decoded == "." || decoded == ".."
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
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date."
            )
        }
        return decoder
    }
}
