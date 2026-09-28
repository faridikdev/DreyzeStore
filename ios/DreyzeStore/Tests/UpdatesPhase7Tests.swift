import CryptoKit
import Foundation
import Network
import XCTest
import ZIPFoundation
@testable import DreyzeStore

final class UpdatesPhase7Tests: XCTestCase {
    private var root: URL!
    private var storage: PackageStorage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DreyzeStoreUpdates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = PackageStorage(rootURL: root.appendingPathComponent("Packages", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor func testUpdateEndToEndDownloadsVerifiesAndRequiresConfirmedInventory() async throws {
        let fixture = try makeFixture(bundleID: "com.dreyze.sample", version: "2.0", build: "200")
        let server = try LocalFixtureHTTPServer(data: fixture.data)
        defer { server.stop() }
        let app = makeApp(bundleID: "com.dreyze.sample", name: "Dreyze Sample", version: "2.0", build: "200", bytes: fixture.data, downloadURL: server.url)
        let update = UpdateAvailable(app: app, installedVersion: "1.0", installedBuild: "100", channel: "stable", latestVersion: app.currentVersion)
        let inventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.0", build: "100")])
        let installer = CompanionInstallStub(inventory: inventory)
        let history = UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeUpdateHistory-\(UUID().uuidString)")!)
        let defaults = UserDefaults(suiteName: "DreyzeUpdates-\(UUID().uuidString)")!
        let model = UpdatesViewModel(
            repository: TestUpdateRepository(apps: [app]),
            inventory: inventory,
            packages: makeNetworkDownloadManager(),
            installation: installer,
            history: history,
            defaults: defaults
        )

        await model.load()
        XCTAssertEqual(model.updates.map(\.app.bundleIdentifier), [app.bundleIdentifier])
        XCTAssertTrue(model.canPerformStoreOperations)
        await model.update(update)

        XCTAssertEqual(inventory.currentSnapshot?.records.first?.version, "2.0")
        XCTAssertEqual(inventory.currentSnapshot?.records.first?.build, "200")
        XCTAssertEqual(history.recentlyUpdated.first?.result, .updated)
        XCTAssertEqual(history.recentlyUpdated.first?.oldVersion, "1.0")
        XCTAssertEqual(history.recentlyUpdated.first?.newVersion, "2.0")
        XCTAssertTrue(model.updates.isEmpty)
        XCTAssertEqual(installer.installedPackages.count, 1)
        XCTAssertEqual(installer.installedPackages.first?.sha256, fixture.sha256)
        XCTAssertEqual(installer.installedPackages.first?.localURL.pathExtension, "ipa")
    }

    @MainActor func testChecksumFailureLeavesInstalledVersionUntouched() async throws {
        let fixture = try makeFixture(bundleID: "com.dreyze.sample", version: "2.0", build: "200")
        let app = makeApp(bundleID: "com.dreyze.sample", name: "Dreyze Sample", version: "2.0", build: "200", bytes: fixture.data, sha256: String(repeating: "0", count: 64))
        let update = UpdateAvailable(app: app, installedVersion: "1.0", installedBuild: "100", channel: "stable", latestVersion: app.currentVersion)
        let inventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.0", build: "100")])
        let installer = CompanionInstallStub(inventory: inventory)
        let history = UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeUpdateHistory-\(UUID().uuidString)")!)
        let model = UpdatesViewModel(
            repository: TestUpdateRepository(apps: [app]), inventory: inventory,
            packages: makeDownloadManager(fixtures: [app.currentVersion.downloadURL: fixture.data]),
            installation: installer, history: history,
            defaults: UserDefaults(suiteName: "DreyzeUpdates-\(UUID().uuidString)")!
        )
        await model.load()
        await model.update(update)

        XCTAssertEqual(inventory.currentSnapshot?.records.first?.version, "1.0")
        XCTAssertTrue(installer.installedPackages.isEmpty)
        XCTAssertTrue(history.recentlyUpdated.isEmpty)
        XCTAssertEqual(history.records.first?.result, .failed)
        guard case .failed(let message) = model.updateState(for: app.bundleIdentifier) else {
            return XCTFail("A checksum mismatch must leave the update in a failed state.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("checksum"))
    }

    @MainActor func testReceiptWithoutFreshInventoryConfirmationNeverReportsUpdated() async throws {
        let fixture = try makeFixture(bundleID: "com.dreyze.sample", version: "2.0", build: "200")
        let app = makeApp(bundleID: "com.dreyze.sample", name: "Dreyze Sample", version: "2.0", build: "200", bytes: fixture.data)
        let update = UpdateAvailable(app: app, installedVersion: "1.0", installedBuild: "100", channel: "stable", latestVersion: app.currentVersion)
        let inventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.0", build: "100")])
        let installer = CompanionInstallStub(inventory: inventory, confirmsInventory: false)
        let history = UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeUpdateHistory-\(UUID().uuidString)")!)
        let model = UpdatesViewModel(
            repository: TestUpdateRepository(apps: [app]), inventory: inventory,
            packages: makeDownloadManager(fixtures: [app.currentVersion.downloadURL: fixture.data]),
            installation: installer, history: history,
            defaults: UserDefaults(suiteName: "DreyzeUpdates-\(UUID().uuidString)")!
        )
        await model.load()
        await model.update(update)

        XCTAssertEqual(inventory.currentSnapshot?.records.first?.version, "1.0")
        XCTAssertTrue(history.recentlyUpdated.isEmpty)
        guard case .failed(let message) = model.updateState(for: app.bundleIdentifier) else {
            return XCTFail("An installation receipt without an updated live inventory must fail confirmation.")
        }
        XCTAssertEqual(message, "Installation could not be confirmed.")
    }

    @MainActor func testIncompatibleReleaseIsNotOfferedAsInstallableUpdate() async throws {
        let fixture = try makeFixture(bundleID: "com.dreyze.sample", version: "2.0", build: "200", minimumOS: "99.0")
        let app = makeApp(bundleID: "com.dreyze.sample", name: "Dreyze Sample", version: "2.0", build: "200", minimumOS: "99.0", bytes: fixture.data)
        let inventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.0", build: "100")])
        let installer = CompanionInstallStub(inventory: inventory)
        let manager = makeDownloadManager(fixtures: [app.currentVersion.downloadURL: fixture.data])
        let model = UpdatesViewModel(
            repository: TestUpdateRepository(apps: [app]), inventory: inventory, packages: manager,
            installation: installer, history: UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeUpdateHistory-\(UUID().uuidString)")!),
            defaults: UserDefaults(suiteName: "DreyzeUpdates-\(UUID().uuidString)")!
        )
        await model.load()
        let update = try XCTUnwrap(model.updates.first)
        await model.update(update)

        guard case .incompatible(let reason) = model.updateState(for: app.bundleIdentifier) else {
            return XCTFail("An unsupported minimum OS must remain incompatible.")
        }
        XCTAssertTrue(reason.contains("99.0"))
        XCTAssertTrue(manager.packages.isEmpty)
        XCTAssertTrue(installer.installedPackages.isEmpty)
    }

    @MainActor func testUpdateAllContinuesAfterOneCompanionFailure() async throws {
        let firstFixture = try makeFixture(bundleID: "com.dreyze.alpha", version: "2.0", build: "200")
        let secondFixture = try makeFixture(bundleID: "com.dreyze.beta", version: "2.0", build: "200")
        let first = makeApp(bundleID: "com.dreyze.alpha", name: "Alpha", version: "2.0", build: "200", bytes: firstFixture.data)
        let second = makeApp(bundleID: "com.dreyze.beta", name: "Beta", version: "2.0", build: "200", bytes: secondFixture.data)
        let inventory = InventoryStub(records: [record(bundleID: first.bundleIdentifier, version: "1.0", build: "100"), record(bundleID: second.bundleIdentifier, version: "1.0", build: "100")])
        let installer = CompanionInstallStub(inventory: inventory, failingBundleIdentifiers: [second.bundleIdentifier])
        let history = UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeUpdateHistory-\(UUID().uuidString)")!)
        let model = UpdatesViewModel(
            repository: TestUpdateRepository(apps: [first, second]), inventory: inventory,
            packages: makeDownloadManager(fixtures: [first.currentVersion.downloadURL: firstFixture.data, second.currentVersion.downloadURL: secondFixture.data]),
            installation: installer, history: history,
            defaults: UserDefaults(suiteName: "DreyzeUpdates-\(UUID().uuidString)")!
        )
        await model.load()
        await model.updateAll()

        XCTAssertEqual(inventory.currentSnapshot?.records.first(where: { $0.canonicalBundleIdentifier == first.bundleIdentifier })?.version, "2.0")
        XCTAssertEqual(inventory.currentSnapshot?.records.first(where: { $0.canonicalBundleIdentifier == second.bundleIdentifier })?.version, "1.0")
        XCTAssertEqual(history.recentlyUpdated.count, 1)
        XCTAssertEqual(model.lastOperationSummary, "1 Updated · 1 Signing Required")
    }

    @MainActor func testSameVersionWithHigherBuildIsDetected() async throws {
        let fixture = try makeFixture(bundleID: "com.dreyze.build", version: "1.0", build: "10")
        let app = makeApp(bundleID: "com.dreyze.build", name: "Build Sample", version: "1.0", build: "10", bytes: fixture.data)
        let inventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.0", build: "9")])
        let model = makeModel(apps: [app], inventory: inventory, packages: makeDownloadManager(fixtures: [app.currentVersion.downloadURL: fixture.data]))

        await model.load()

        XCTAssertEqual(model.updates.first?.installedBuild, "9")
        XCTAssertEqual(model.updates.first?.latestVersion.build, "10")
    }

    @MainActor func testStableChannelDoesNotOfferBetaOnlyRelease() async throws {
        let fixture = try makeFixture(bundleID: "com.dreyze.beta", version: "2.0-beta.1", build: "20")
        let app = makeApp(bundleID: "com.dreyze.beta", name: "Beta Sample", version: "2.0-beta.1", build: "20", bytes: fixture.data, channel: "beta")
        let stableInventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.9", build: "19")])
        let stableModel = makeModel(apps: [app], inventory: stableInventory, packages: makeDownloadManager(fixtures: [app.currentVersion.downloadURL: fixture.data]))
        await stableModel.load()
        XCTAssertTrue(stableModel.updates.isEmpty)

        let defaults = UserDefaults(suiteName: "DreyzeBetaUpdates-\(UUID().uuidString)")!
        defaults.set("beta", forKey: "dreyze.updates.channel.v1")
        let betaInventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.9", build: "19")])
        let betaModel = UpdatesViewModel(
            repository: TestUpdateRepository(apps: [app]), inventory: betaInventory,
            packages: makeDownloadManager(fixtures: [app.currentVersion.downloadURL: fixture.data]),
            installation: CompanionInstallStub(inventory: betaInventory),
            history: UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeBetaHistory-\(UUID().uuidString)")!), defaults: defaults
        )
        await betaModel.load()
        XCTAssertEqual(betaModel.updates.first?.latestVersion.channel, "beta")
    }

    @MainActor func testCachedInventoryNeverEnablesInstallationOperations() async throws {
        let fixture = try makeFixture(bundleID: "com.dreyze.offline", version: "2.0", build: "2")
        let app = makeApp(bundleID: "com.dreyze.offline", name: "Offline Sample", version: "2.0", build: "2", bytes: fixture.data)
        let inventory = InventoryStub(records: [record(bundleID: app.bundleIdentifier, version: "1.0", build: "1")], isLive: false)
        let installer = CompanionInstallStub(inventory: inventory)
        let model = makeModel(apps: [app], inventory: inventory, packages: makeDownloadManager(fixtures: [app.currentVersion.downloadURL: fixture.data]), installation: installer)

        await model.load()
        XCTAssertFalse(model.isInventoryLive)
        XCTAssertFalse(model.canPerformStoreOperations)
        await model.update(UpdateAvailable(app: app, installedVersion: "1.0", installedBuild: "1", channel: "stable", latestVersion: app.currentVersion))
        XCTAssertTrue(installer.installedPackages.isEmpty)
    }

    @MainActor func testSigningRefreshRequiresLiveRenewedInventory() async throws {
        let app = makeApp(bundleID: "com.dreyze.refresh", name: "Refresh Sample", version: "1.0", build: "1", bytes: Data("metadata-only".utf8))
        let original = record(bundleID: app.bundleIdentifier, version: "1.0", build: "1", expiration: Date().addingTimeInterval(2 * 86_400))
        let inventory = InventoryStub(records: [original])
        let installer = CompanionInstallStub(inventory: inventory, refreshSucceeds: true)
        let history = UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeRefreshHistory-\(UUID().uuidString)")!)
        let model = makeModel(apps: [app], inventory: inventory, packages: makeDownloadManager(fixtures: [:]), installation: installer, history: history)

        await model.load()
        let expiring = try XCTUnwrap(model.expiringRecords.first)
        await model.refresh(expiring)

        XCTAssertEqual(inventory.currentSnapshot?.records.first?.version, "1.0")
        XCTAssertEqual(history.records.first?.result, .refreshed)
        XCTAssertGreaterThan(inventory.currentSnapshot?.records.first?.provisionExpiration ?? .distantPast, original.provisionExpiration ?? .distantPast)
    }

    @MainActor func testFailedRefreshDoesNotRecordSuccess() async throws {
        let app = makeApp(bundleID: "com.dreyze.refreshfail", name: "Refresh Failure", version: "1.0", build: "1", bytes: Data("metadata-only".utf8))
        let original = record(bundleID: app.bundleIdentifier, version: "1.0", build: "1", expiration: Date().addingTimeInterval(2 * 86_400))
        let inventory = InventoryStub(records: [original])
        let installer = CompanionInstallStub(inventory: inventory, refreshSucceeds: false)
        let history = UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeRefreshFailHistory-\(UUID().uuidString)")!)
        let model = makeModel(apps: [app], inventory: inventory, packages: makeDownloadManager(fixtures: [:]), installation: installer, history: history)

        await model.load()
        await model.refresh(original)

        XCTAssertEqual(inventory.currentSnapshot?.records.first?.provisionExpiration, original.provisionExpiration)
        XCTAssertEqual(history.records.first?.result, .failed)
        XCTAssertFalse(history.records.contains(where: { $0.result == .refreshed }))
    }

    @MainActor func testUninstallRequiresAndConfirmsLiveInventory() async throws {
        let app = makeApp(bundleID: "com.dreyze.remove", name: "Remove Sample", version: "1.0", build: "1", bytes: Data("metadata-only".utf8))
        let original = record(bundleID: app.bundleIdentifier, version: "1.0", build: "1")
        let inventory = InventoryStub(records: [original])
        let installer = CompanionInstallStub(inventory: inventory)
        let model = makeModel(apps: [app], inventory: inventory, packages: makeDownloadManager(fixtures: [:]), installation: installer)

        await model.load()
        let removed = await model.uninstall(original)
        XCTAssertTrue(removed)
        XCTAssertFalse(inventory.currentSnapshot?.records.contains(where: { $0.installedBundleIdentifier == original.installedBundleIdentifier }) ?? true)
    }

    @MainActor func testExpiredInventoryCacheIsDiscarded() async throws {
        let defaults = UserDefaults(suiteName: "DreyzeExpiredInventory-\(UUID().uuidString)")!
        let expired = InstalledInventorySnapshot(records: [], lastChecked: Date().addingTimeInterval(-31 * 86_400), deviceIdentifier: "device-hash", isLive: false)
        defaults.set(try JSONEncoder().encode(expired), forKey: "dreyze.inventory.companion-snapshot.v1")
        let service = InstalledInventoryService(provider: OfflineInventoryProvider(deviceIdentifier: "device-hash"), defaults: defaults)

        let result = await service.synchronize()

        XCTAssertNil(result)
        guard case .unavailable = service.state else { return XCTFail("An expired snapshot must not be presented as current inventory.") }
    }

    @MainActor func testInventoryCacheIsScopedToPairedDevice() async throws {
        let defaults = UserDefaults(suiteName: "DreyzeWrongDeviceInventory-\(UUID().uuidString)")!
        let cached = InstalledInventorySnapshot(records: [], lastChecked: Date(), deviceIdentifier: "another-device", isLive: false)
        defaults.set(try JSONEncoder().encode(cached), forKey: "dreyze.inventory.companion-snapshot.v1")
        let service = InstalledInventoryService(provider: OfflineInventoryProvider(deviceIdentifier: "device-hash"), defaults: defaults)

        let result = await service.synchronize()

        XCTAssertNil(result)
        guard case .unavailable = service.state else { return XCTFail("Inventory from another paired device must not be reused.") }
    }

    @MainActor private func makeDownloadManager(fixtures: [URL: Data]) -> DownloadManager {
        DownloadManager(storage: storage, transport: FixtureDownloadTransport(fixtures: fixtures))
    }

    @MainActor private func makeNetworkDownloadManager() -> DownloadManager {
        let transport = URLSessionPackageDownloadTransport(storage: storage, mode: .foregroundForTests, urlPolicy: .loopbackHTTPForTests)
        return DownloadManager(storage: storage, transport: transport, urlPolicy: .loopbackHTTPForTests)
    }

    @MainActor private func makeModel(
        apps: [StoreApp],
        inventory: InventoryStub,
        packages: DownloadManager,
        installation: CompanionInstallStub? = nil,
        history: UpdateHistoryStore? = nil
    ) -> UpdatesViewModel {
        UpdatesViewModel(
            repository: TestUpdateRepository(apps: apps), inventory: inventory, packages: packages,
            installation: installation ?? CompanionInstallStub(inventory: inventory),
            history: history ?? UpdateHistoryStore(defaults: UserDefaults(suiteName: "DreyzeHistory-\(UUID().uuidString)")!),
            defaults: UserDefaults(suiteName: "DreyzeUpdates-\(UUID().uuidString)")!
        )
    }

    private func makeApp(bundleID: String, name: String, version: String, build: String, minimumOS: String = "16.0", bytes: Data, sha256: String? = nil, channel: String = "stable", downloadURL: URL? = nil) -> StoreApp {
        let url = downloadURL ?? URL(string: "https://packages.example.invalid/\(bundleID).ipa")!
        return StoreApp(
            id: "app-\(bundleID.replacingOccurrences(of: ".", with: "-"))",
            bundleIdentifier: bundleID,
            name: name,
            shortDescription: "Runtime-generated fixture app.",
            developer: Developer(id: "dreyze-labs", name: "Dreyze Labs", websiteURL: nil),
            category: StoreCategory(id: "utilities", name: "Utilities", appCount: 1),
            iconURL: URL(string: "https://assets.example.invalid/icon.png")!,
            currentVersion: AppVersion(id: "release-\(build)", version: version, build: build, versionDate: Date(), minimumOSVersion: minimumOS, downloadURL: url, sha256: sha256 ?? Self.digest(bytes), size: Int64(bytes.count), releaseNotes: "Test release.", channel: channel),
            repositoryIdentifier: "com.dreyzestore.official",
            repositoryName: "DreyzeStore",
            description: nil,
            screenshots: nil
        )
    }

    private func record(bundleID: String, version: String, build: String, expiration: Date = Date().addingTimeInterval(30 * 24 * 60 * 60)) -> InstalledAppRecord {
        InstalledAppRecord(
            originalBundleIdentifier: bundleID,
            installedBundleIdentifier: bundleID,
            version: version,
            build: build,
            releaseSHA256: String(repeating: "a", count: 64),
            teamIdentifier: "TEAM123",
            provisionExpiration: expiration,
            installedAt: Date(),
            deviceIdentifier: "device-hash",
            source: .companionConfirmed
        )
    }

    private func makeFixture(bundleID: String, version: String, build: String, minimumOS: String = "16.0") throws -> (data: Data, sha256: String) {
        let sourceRoot = root.appendingPathComponent("Sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("fixture-\(UUID().uuidString).ipa")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let appName = "DreyzeFixture"
        let infoURL = sourceRoot.appendingPathComponent("Info.plist")
        let info: [String: String] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": appName,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "MinimumOSVersion": minimumOS
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let executableURL = sourceRoot.appendingPathComponent(appName)
        try Data("generated fixture executable".utf8).write(to: executableURL)
        try archive.addEntry(with: "Payload/\(appName).app/Info.plist", fileURL: infoURL, compressionMethod: .deflate)
        try archive.addEntry(with: "Payload/\(appName).app/\(appName)", fileURL: executableURL, compressionMethod: .deflate)
        let data = try Data(contentsOf: archiveURL)
        return (data, Self.digest(data))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class LocalFixtureHTTPServer {
    private let data: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dreyzestore.tests.local-ipa-http")
    private let ready = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var startupError: Error?
    private var boundPort: UInt16?

    init(data: Data) throws {
        self.data = data
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateLock.lock()
                self.boundPort = listener.port?.rawValue
                self.stateLock.unlock()
                self.ready.signal()
            case .failed(let error):
                self.stateLock.lock()
                self.startupError = error
                self.stateLock.unlock()
                self.ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw LocalHTTPServerError.startupTimedOut }
        stateLock.lock()
        let error = startupError
        let port = boundPort
        stateLock.unlock()
        if let error { throw error }
        guard port != nil else { throw LocalHTTPServerError.portUnavailable }
    }

    var url: URL {
        stateLock.lock(); defer { stateLock.unlock() }
        return URL(string: "http://127.0.0.1:\(boundPort!)/sample.ipa")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(self.data.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(self.data)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private enum LocalHTTPServerError: Error {
    case startupTimedOut
    case portUnavailable
}

private struct OfflineInventoryProvider: InstalledAppInventoryProviding {
    let deviceIdentifier: String
    var expectedDeviceIdentifier: String? { deviceIdentifier }
    func fetchInstalledInventory() async throws -> InstalledInventorySnapshot { throw URLError(.notConnectedToInternet) }
}

@MainActor
private final class InventoryStub: UpdateInventorySynchronizing {
    var state: InstalledInventoryState
    private(set) var currentSnapshot: InstalledInventorySnapshot?
    private(set) var isLive: Bool

    init(records: [InstalledAppRecord], isLive: Bool = true) {
        self.isLive = isLive
        let snapshot = InstalledInventorySnapshot(records: records, lastChecked: Date(), deviceIdentifier: "device-hash", isLive: isLive)
        self.currentSnapshot = snapshot
        self.state = isLive ? .live(snapshot) : .cached(snapshot)
    }

    func synchronize() async -> InstalledInventorySnapshot? {
        guard let currentSnapshot else { return nil }
        let refreshed = InstalledInventorySnapshot(records: currentSnapshot.records, lastChecked: currentSnapshot.lastChecked, deviceIdentifier: currentSnapshot.deviceIdentifier, isLive: isLive)
        currentSnapshot = refreshed
        state = isLive ? .live(refreshed) : .cached(refreshed)
        return refreshed
    }

    func replace(records: [InstalledAppRecord]) {
        let snapshot = InstalledInventorySnapshot(records: records, lastChecked: Date(), deviceIdentifier: "device-hash", isLive: true)
        currentSnapshot = snapshot
        state = .live(snapshot)
        isLive = true
    }
}

@MainActor
private final class CompanionInstallStub: UpdateInstallationManaging {
    private let inventory: InventoryStub
    private let failingBundleIdentifiers: Set<String>
    private let confirmsInventory: Bool
    private let refreshSucceeds: Bool
    private(set) var installedPackages: [VerifiedPackage] = []

    init(inventory: InventoryStub, confirmsInventory: Bool = true, failingBundleIdentifiers: Set<String> = [], refreshSucceeds: Bool = false) {
        self.inventory = inventory
        self.confirmsInventory = confirmsInventory
        self.failingBundleIdentifiers = failingBundleIdentifiers
        self.refreshSucceeds = refreshSucceeds
    }

    func checkCompanionAvailability() async -> BackendAvailability { .available }

    func installForUpdate(package: VerifiedPackage, onState: @escaping InstallationStateObserver) async -> InstallationDirective {
        installedPackages.append(package)
        onState(.connectingToCompanion)
        onState(.signing)
        if failingBundleIdentifiers.contains(package.bundleIdentifier) {
            let failure = InstallationFailure(code: .installationFailed, title: "Signing Failed", userMessage: "Test Companion signing failure.", technicalDetails: "mock")
            return .failed(failure)
        }
        onState(.installing)
        let installed = InstalledApplication(bundleIdentifier: package.bundleIdentifier, version: package.version, build: package.build, sourceIdentifier: "windows-companion", installedAt: Date())
        if confirmsInventory {
            let replacement = InstalledAppRecord(
                originalBundleIdentifier: package.bundleIdentifier,
                installedBundleIdentifier: package.bundleIdentifier,
                version: package.version,
                build: package.build,
                releaseSHA256: package.sha256,
                teamIdentifier: "TEAM123",
                provisionExpiration: Date().addingTimeInterval(30 * 24 * 60 * 60),
                installedAt: Date(),
                deviceIdentifier: "device-hash",
                source: .companionConfirmed
            )
            let remaining = inventory.currentSnapshot?.records.filter { $0.canonicalBundleIdentifier != package.bundleIdentifier } ?? []
            inventory.replace(records: remaining + [replacement])
        }
        return .installed(installed)
    }

    func refreshInstalledApp(_ app: InstalledAppRecord) async -> InstallationDirective {
        guard refreshSucceeds else {
            return .failed(InstallationFailure(code: .signingRequired, title: "Signing Required", userMessage: "Test Companion signing setup required.", technicalDetails: "test fixture"))
        }
        let expiration = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let refreshed = InstalledAppRecord(
            originalBundleIdentifier: app.originalBundleIdentifier,
            installedBundleIdentifier: app.installedBundleIdentifier,
            version: app.version,
            build: app.build,
            releaseSHA256: app.releaseSHA256,
            teamIdentifier: app.teamIdentifier,
            provisionExpiration: expiration,
            installedAt: app.installedAt,
            deviceIdentifier: app.deviceIdentifier,
            source: .companionConfirmed
        )
        inventory.replace(records: [refreshed])
        return .installed(InstalledApplication(bundleIdentifier: app.installedBundleIdentifier, version: app.version ?? "", build: app.build, sourceIdentifier: "windows-companion", installedAt: Date()))
    }

    func uninstall(bundleIdentifier: String, using backendIdentifier: String) async -> UninstallationResult {
        inventory.replace(records: inventory.currentSnapshot?.records.filter { $0.installedBundleIdentifier != bundleIdentifier } ?? [])
        return .uninstalled
    }
    func cancel() { }
}

private actor TestUpdateRepository: StoreRepository {
    private let appsValue: [StoreApp]

    init(apps: [StoreApp]) { self.appsValue = apps }

    func apps(page: Int, limit: Int, category: String?, sort: CatalogSort) async throws -> StoreLoad<AppsPage> {
        StoreLoad(value: AppsPage(data: Array(appsValue.prefix(limit)), meta: PageMetadata(requestId: nil, page: page, pageSize: limit, hasMore: false, nextCursor: nil)), source: .network, receivedAt: Date())
    }
    func categories() async throws -> StoreLoad<[StoreCategory]> { StoreLoad(value: [], source: .network, receivedAt: Date()) }
    func featured() async throws -> StoreLoad<[FeaturedSection]> { StoreLoad(value: [], source: .network, receivedAt: Date()) }
    func search(_ term: String, page: Int, limit: Int) async throws -> StoreLoad<AppsPage> { try await apps(page: page, limit: limit, category: nil, sort: .name) }
    func app(id: String) async throws -> StoreLoad<StoreApp> { StoreLoad(value: appsValue[0], source: .network, receivedAt: Date()) }
    func versions(appID: String) async throws -> StoreLoad<[AppVersion]> { StoreLoad(value: appsValue.map(\.currentVersion), source: .network, receivedAt: Date()) }
    func updates(for installed: [InstalledVersion]) async throws -> [UpdateAvailable] {
        appsValue.compactMap { app in
            guard let current = installed.first(where: { $0.bundleIdentifier == app.bundleIdentifier }),
                  (current.channel == "beta" || app.currentVersion.channel == "stable"),
                  VersionComparator.isNewerRelease(candidateVersion: app.currentVersion.version, candidateBuild: app.currentVersion.build, installedVersion: current.installedVersion, installedBuild: current.installedBuild) else { return nil }
            return UpdateAvailable(app: app, installedVersion: current.installedVersion, installedBuild: current.installedBuild, channel: current.channel, latestVersion: app.currentVersion)
        }
    }
    func lookupApps(bundleIdentifiers: [String], channel: AppUpdateChannel) async throws -> [StoreApp] {
        appsValue.filter { bundleIdentifiers.contains($0.bundleIdentifier) && (channel == .beta || $0.currentVersion.channel == "stable") }
    }
    func repositoryManifest() async throws -> StoreLoad<RepositoryManifest> { fatalError("Not used in update tests.") }
}

private final class FixtureDownloadTransport: PackageDownloadTransport, @unchecked Sendable {
    private let fixtures: [URL: Data]
    init(fixtures: [URL: Data]) { self.fixtures = fixtures }
    func download(intent: PackageDownloadIntent, destinationURL: URL, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> PackageTransferResponse {
        guard let bytes = fixtures[intent.release.downloadURL] else { throw PackageDownloadFailure(.http, httpStatus: 404) }
        try bytes.write(to: destinationURL, options: .atomic)
        onProgress(DownloadProgress(receivedBytes: Int64(bytes.count), expectedBytes: Int64(bytes.count)))
        return PackageTransferResponse(fileURL: destinationURL, finalURL: intent.release.downloadURL, statusCode: 200, receivedBytes: Int64(bytes.count))
    }
    func cancel(transferID: UUID) { }
    func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) { handler() }
}
