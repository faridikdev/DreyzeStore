import Foundation

public actor NetworkStoreRepository: StoreRepository {
    private let client: APIClient
    private let cache: any CatalogSnapshotStore
    private let cacheLifetime: TimeInterval

    public init(client: APIClient, cache: any CatalogSnapshotStore = FileCatalogSnapshotStore(), cacheLifetime: TimeInterval = 7 * 24 * 60 * 60) {
        self.client = client
        self.cache = cache
        self.cacheLifetime = cacheLifetime
    }

    public func apps(page: Int, limit: Int, category: String?, sort: CatalogSort) async throws -> StoreLoad<AppsPage> {
        let key = "apps:p\(page):l\(limit):c\(category ?? "all"):s\(sort.rawValue)"
        return try await cached(key: key) { try await self.client.apps(page: page, limit: limit, category: category, sort: sort) }
    }

    public func categories() async throws -> StoreLoad<[StoreCategory]> {
        try await cached(key: "categories") { try await self.client.categories() }
    }

    public func featured() async throws -> StoreLoad<[FeaturedSection]> {
        try await cached(key: "featured") { try await self.client.featured() }
    }

    public func search(_ term: String, page: Int, limit: Int) async throws -> StoreLoad<AppsPage> {
        try await cached(key: "search:\(term.lowercased()):p\(page):l\(limit)") { try await self.client.search(term, page: page, limit: limit) }
    }

    public func app(id: String) async throws -> StoreLoad<StoreApp> {
        try await cached(key: "app:\(id)") { try await self.client.app(id: id) }
    }

    public func versions(appID: String) async throws -> StoreLoad<[AppVersion]> {
        try await cached(key: "versions:\(appID)") { try await self.client.versions(appID: appID) }
    }

    public func lookupApps(bundleIdentifiers: [String], channel: AppUpdateChannel) async throws -> [StoreApp] {
        guard bundleIdentifiers.count <= 25 else { throw StoreError.invalidRequest }
        let key = "lookup:\(channel.rawValue):\(bundleIdentifiers.sorted().joined(separator: ","))"
        let result = try await cached(key: key) { try await self.client.lookupApps(bundleIdentifiers: bundleIdentifiers, channel: channel) }
        return result.value
    }

    public func updates(for installed: [InstalledVersion]) async throws -> [UpdateAvailable] {
        try await client.updates(for: installed)
    }

    public func repositoryManifest() async throws -> StoreLoad<RepositoryManifest> {
        try await cached(key: "repository-manifest") { try await self.client.repositoryManifest() }
    }

    private func cached<Value: Codable & Sendable>(key: String, operation: () async throws -> Value) async throws -> StoreLoad<Value> {
        do {
            let value = try await operation()
            let now = Date()
            if let data = try? JSONEncoder.catalog.encode(value) { try? await cache.save(key: key, data: data, receivedAt: now) }
            return StoreLoad(value: value, source: .network, receivedAt: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StoreError where error == .networkUnavailable {
            guard let snapshot = try? await cache.load(key: key, now: Date(), maximumAge: cacheLifetime),
                  let value = try? JSONDecoder.catalog.decode(Value.self, from: snapshot.data) else { throw error }
            return StoreLoad(value: value, source: .cache, receivedAt: snapshot.receivedAt)
        }
    }
}

private extension JSONEncoder {
    static var catalog: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var catalog: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
