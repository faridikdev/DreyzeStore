import Foundation
import XCTest
@testable import DreyzeStore

final class StorePhase3Tests: XCTestCase {
    func testAPIClientDecodesCatalogPageAndPaginationMetadata() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/apps")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "limit" })?.value, "24")
            return (200, Self.appsEnvelope(page: 1, hasMore: true))
        }
        defer { StubURLProtocol.handler = nil }
        let client = try Self.client()
        let page = try await client.apps(page: 1, limit: 24, category: nil, sort: .name)
        XCTAssertEqual(page.data.first?.name, "Orbit Timer")
        XCTAssertEqual(page.data.first?.shortDescription, "Orbit Timer for your day.")
        XCTAssertEqual(page.meta?.page, 1)
        XCTAssertEqual(page.meta?.hasMore, true)
    }

    func testAppDetailsAndVersionHistoryDecode() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/versions") == true {
                return (200, Data(#"{"data":[{"id":"release-1","version":"1.10.0","build":"10","versionDate":"2026-09-20T10:00:00Z","minimumOSVersion":"16.0","downloadURL":"https://cdn.example.invalid/app.ipa","sha256":"\#(String(repeating: "a", count: 64))","size":1200,"releaseNotes":"Faster.","channel":"stable"}]}"#.utf8))
            }
            return (200, Self.detailsEnvelope())
        }
        defer { StubURLProtocol.handler = nil }
        let client = try Self.client()
        let app = try await client.app(id: "app-orbit-timer")
        let versions = try await client.versions(appID: app.id)
        XCTAssertEqual(app.description, "A fictional timer for local development.")
        XCTAssertEqual(app.screenshots?.first?.alt, "Timer overview")
        XCTAssertEqual(versions.first?.version, "1.10.0")
    }

    func testRepositoryManifestModelDecodes() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"schemaVersion":1,"name":"Dreyze","identifier":"com.dreyze.repo","description":"Store","icon":"https://cdn.example.invalid/icon.png","generatedAt":"2026-09-27T12:00:00Z","apps":[]}"#.utf8)) }
        defer { StubURLProtocol.handler = nil }
        let manifest = try await Self.client().repositoryManifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.identifier, "com.dreyze.repo")
        XCTAssertTrue(manifest.apps.isEmpty)
    }

    func testBundleLookupUsesBoundedPOSTAndDecodesPublishedApp() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/apps/lookup")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["bundleIdentifiers"] as? [String], ["com.dreyze.orbittimer"])
            XCTAssertEqual(json["channel"] as? String, "stable")
            return (200, Self.appsEnvelope(page: 1, hasMore: false))
        }
        defer { StubURLProtocol.handler = nil }
        let apps = try await Self.client().lookupApps(bundleIdentifiers: ["com.dreyze.orbittimer"], channel: .stable)
        XCTAssertEqual(apps.first?.bundleIdentifier, "com.dreyze.orbittimer")
    }

    func testSearchAndUpdateEndpointsEncodeTheirQueriesAndDecodeResponses() async throws {
        StubURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if request.url?.path == "/api/v1/search" {
                XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "Orbit Timer")
                return (200, Self.appsEnvelope(page: 1, hasMore: false))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/updates")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody)
            let parsedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let parsedApps = try XCTUnwrap(parsedBody["apps"] as? [[String: Any]])
            XCTAssertEqual(parsedApps.first?["bundleIdentifier"] as? String, "com.dreyze.orbittimer")
            XCTAssertEqual(parsedApps.first?["version"] as? String, "1.9.0")
            XCTAssertEqual(parsedApps.first?["build"] as? String, "9")
            XCTAssertEqual(parsedApps.first?["channel"] as? String, "stable")
            let version = #"{"id":"release-1","version":"1.10.0","build":"10","versionDate":"2026-09-20T10:00:00Z","minimumOSVersion":"16.0","downloadURL":"https://cdn.example.invalid/orbit.ipa","sha256":"\#(String(repeating: "a", count: 64))","size":1200,"releaseNotes":"Faster.","channel":"stable"}"#
            return (200, Data(#"{"data":[{"app":{"id":"app-orbit-timer","bundleIdentifier":"com.dreyze.orbittimer","name":"Orbit Timer","shortDescription":"A local timer.","developer":{"id":"dev-orbit","name":"Orbit Labs"},"category":{"id":"utilities","name":"Utilities","appCount":1},"iconURL":"https://cdn.example.invalid/orbit.png","currentVersion":\#(version),"repositoryIdentifier":"com.dreyze.official","repositoryName":"DreyzeStore"},"installedVersion":"1.9.0","installedBuild":"9","channel":"stable","latestVersion":\#(version)}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let client = try Self.client()
        let search = try await client.search("Orbit Timer")
        let updates = try await client.updates(for: [InstalledVersion(bundleIdentifier: "com.dreyze.orbittimer", installedVersion: "1.9.0", installedBuild: "9")])
        XCTAssertEqual(search.data.first?.name, "Orbit Timer")
        XCTAssertEqual(updates.first?.latestVersion.version, "1.10.0")
    }

    func testSearchUsesQueryAndDebounceCancelsEarlierTerm() async throws {
        let repository = RecordingStoreRepository()
        let defaultsSuiteName = UUID().uuidString
        let model = await MainActor.run {
            SearchViewModel(
                repository: repository,
                defaults: UserDefaults(suiteName: defaultsSuiteName)!,
                debounceNanoseconds: 10_000_000
            )
        }
        await MainActor.run { model.text = "Orbit" }
        try await Task.sleep(nanoseconds: 2_000_000)
        await MainActor.run { model.text = "Timer" }
        try await Task.sleep(nanoseconds: 100_000_000)
        let terms = await repository.searchTerms
        XCTAssertEqual(terms, ["Timer"])
        let recent = await MainActor.run { model.recentSearches }
        XCTAssertEqual(recent, ["Timer"])
    }

    func testAppsViewModelLoadsNextPageWithoutDuplicatingFirstPage() async {
        let repository = RecordingStoreRepository()
        let model = await MainActor.run { AppsViewModel(repository: repository) }
        await model.load()
        let firstApp = await MainActor.run { model.apps[0] }
        await model.loadNextPageIfNeeded(current: firstApp)
        let apps = await MainActor.run { model.apps }
        XCTAssertEqual(apps.map(\.id), ["app-orbit-timer", "app-aurora-notes"])
    }

    func testExpiredCatalogSnapshotIsDiscarded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileCatalogSnapshotStore(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        try await store.save(key: "catalog", data: Data("snapshot".utf8), receivedAt: receivedAt)
        let valid = try await store.load(key: "catalog", now: receivedAt.addingTimeInterval(60), maximumAge: 120)
        let expired = try await store.load(key: "catalog", now: receivedAt.addingTimeInterval(121), maximumAge: 120)
        XCTAssertEqual(valid?.data, Data("snapshot".utf8))
        XCTAssertNil(expired)
    }

    func testNetworkFailureFallsBackToValidCatalogCache() async throws {
        let store = MemorySnapshotStore()
        let page = AppsPage(data: [Self.sampleApp()], meta: PageMetadata(requestId: nil, page: 1, pageSize: 24, hasMore: false, nextCursor: nil))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await store.save(key: "apps:p1:l24:call:sname", data: encoder.encode(page), receivedAt: Date())
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        defer { StubURLProtocol.handler = nil }
        let repository = NetworkStoreRepository(client: try Self.client(), cache: store)
        let result = try await repository.apps(page: 1, limit: 24, category: nil, sort: .name)
        XCTAssertEqual(result.source, .cache)
        XCTAssertEqual(result.value.data.first?.name, "Orbit Timer")
    }

    func testErrorMappingKeepsTechnicalDetailsOutOfUserMessage() {
        XCTAssertEqual(StoreError.networkUnavailable.userMessage, "Check your internet connection and try again.")
        XCTAssertFalse(StoreError.serverFailure(statusCode: 500).userMessage.contains("500"))
    }

    func testUpdatesRequestIsBounded() async throws {
        let installed = (0..<26).map { InstalledVersion(bundleIdentifier: "com.example.app\($0)", installedVersion: "1.0.0") }
        do {
            _ = try await Self.client().updates(for: installed)
            XCTFail("Expected oversized installed inventory to be rejected")
        } catch let error as StoreError {
            XCTAssertEqual(error, .invalidRequest)
        }
    }

    private static func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://unit.test/api/v1")!), session: session)
    }

    private static func appsEnvelope(page: Int, hasMore: Bool) -> Data {
        Data(#"{"data":[{"id":"app-orbit-timer","bundleIdentifier":"com.dreyze.orbittimer","name":"Orbit Timer","shortDescription":"Orbit Timer for your day.","developer":{"id":"dev-dreyze","name":"Dreyze Labs"},"category":{"id":"utilities","name":"Utilities","appCount":1},"iconURL":"https://cdn.example.invalid/orbit.png","currentVersion":{"id":"release-1","version":"1.10.0","build":"10","versionDate":"2026-09-20T10:00:00Z","minimumOSVersion":"16.0","downloadURL":"https://cdn.example.invalid/orbit.ipa","sha256":"\#(String(repeating: "a", count: 64))","size":1200,"releaseNotes":"Faster.","channel":"stable"},"repositoryIdentifier":"com.dreyze.official","repositoryName":"DreyzeStore"}],"meta":{"page":\#(page),"pageSize":24,"hasMore":\#(hasMore)}}"#.utf8)
    }

    private static func detailsEnvelope() -> Data {
        Data(#"{"data":{"id":"app-orbit-timer","bundleIdentifier":"com.dreyze.orbittimer","name":"Orbit Timer","shortDescription":"Orbit Timer for your day.","developer":{"id":"dev-dreyze","name":"Dreyze Labs","websiteURL":"https://dreyzestore.invalid"},"category":{"id":"utilities","name":"Utilities","appCount":1},"iconURL":"https://cdn.example.invalid/orbit.png","currentVersion":{"id":"release-1","version":"1.10.0","build":"10","versionDate":"2026-09-20T10:00:00Z","minimumOSVersion":"16.0","downloadURL":"https://cdn.example.invalid/orbit.ipa","sha256":"\#(String(repeating: "a", count: 64))","size":1200,"releaseNotes":"Faster.","channel":"stable"},"repositoryIdentifier":"com.dreyze.official","repositoryName":"DreyzeStore","description":"A fictional timer for local development.","screenshots":[{"url":"https://cdn.example.invalid/screen.png","width":1179,"height":2556,"alt":"Timer overview"}]}}"#.utf8)
    }

    fileprivate static func sampleApp() -> StoreApp {
        StoreApp(id: "app-orbit-timer", bundleIdentifier: "com.dreyze.orbittimer", name: "Orbit Timer", shortDescription: "Orbit Timer for your day.", developer: Developer(id: "dev-dreyze", name: "Dreyze Labs", websiteURL: nil), category: StoreCategory(id: "utilities", name: "Utilities", appCount: 1), iconURL: URL(string: "https://cdn.example.invalid/orbit.png")!, currentVersion: AppVersion(id: "release-1", version: "1.10.0", build: "10", versionDate: Date(timeIntervalSince1970: 1), minimumOSVersion: "16.0", downloadURL: URL(string: "https://cdn.example.invalid/orbit.ipa")!, sha256: String(repeating: "a", count: 64), size: 1200, releaseNotes: "Faster.", channel: "stable"), repositoryIdentifier: "com.dreyze.official", repositoryName: "DreyzeStore", description: nil, screenshots: nil)
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private actor MemorySnapshotStore: CatalogSnapshotStore {
    private var values: [String: CatalogSnapshot] = [:]
    func load(key: String, now: Date, maximumAge: TimeInterval) async throws -> CatalogSnapshot? {
        guard let snapshot = values[key], now.timeIntervalSince(snapshot.receivedAt) <= maximumAge else { return nil }
        return snapshot
    }
    func save(key: String, data: Data, receivedAt: Date) async throws { values[key] = CatalogSnapshot(data: data, receivedAt: receivedAt) }
    func clear() async throws { values.removeAll() }
}

private actor RecordingStoreRepository: StoreRepository {
    private(set) var searchTerms: [String] = []
    private var pageCalls = 0
    private let first = StorePhase3Tests.sampleApp()
    private var second: StoreApp {
        StoreApp(id: "app-aurora-notes", bundleIdentifier: "com.dreyze.auroranotes", name: "Aurora Notes", shortDescription: "Aurora Notes for local development.", developer: Developer(id: "dev-dreyze", name: "Dreyze Labs", websiteURL: nil), category: StoreCategory(id: "productivity", name: "Productivity", appCount: 1), iconURL: URL(string: "https://cdn.example.invalid/aurora.png")!, currentVersion: first.currentVersion, repositoryIdentifier: "com.dreyze.official", repositoryName: "DreyzeStore", description: nil, screenshots: nil)
    }
    func apps(page: Int, limit: Int, category: String?, sort: CatalogSort) async throws -> StoreLoad<AppsPage> {
        pageCalls += 1
        let item = page == 1 ? first : second
        let pageData = AppsPage(data: [item], meta: PageMetadata(requestId: nil, page: page, pageSize: limit, hasMore: page == 1, nextCursor: nil))
        return StoreLoad(value: pageData, source: .network, receivedAt: Date())
    }
    func categories() async throws -> StoreLoad<[StoreCategory]> { StoreLoad(value: [], source: .network, receivedAt: Date()) }
    func featured() async throws -> StoreLoad<[FeaturedSection]> { StoreLoad(value: [], source: .network, receivedAt: Date()) }
    func search(_ term: String, page: Int, limit: Int) async throws -> StoreLoad<AppsPage> {
        searchTerms.append(term)
        let result = AppsPage(data: [first], meta: PageMetadata(requestId: nil, page: page, pageSize: limit, hasMore: false, nextCursor: nil))
        return StoreLoad(value: result, source: .network, receivedAt: Date())
    }
    func app(id: String) async throws -> StoreLoad<StoreApp> { StoreLoad(value: first, source: .network, receivedAt: Date()) }
    func versions(appID: String) async throws -> StoreLoad<[AppVersion]> { StoreLoad(value: [first.currentVersion], source: .network, receivedAt: Date()) }
    func updates(for installed: [InstalledVersion]) async throws -> [UpdateAvailable] { [] }
    func lookupApps(bundleIdentifiers: [String], channel: AppUpdateChannel) async throws -> [StoreApp] {
        [first, second].filter { bundleIdentifiers.contains($0.bundleIdentifier) }
    }
    func repositoryManifest() async throws -> StoreLoad<RepositoryManifest> { fatalError("Not used by this test") }
}
