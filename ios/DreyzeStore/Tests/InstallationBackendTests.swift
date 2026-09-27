import Foundation
import CryptoKit
import XCTest
import ZIPFoundation
@testable import DreyzeStore

final class InstallationBackendTests: XCTestCase {
    private var root: URL!
    private var storage: PackageStorage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DreyzeStoreInstallationTests-\(UUID().uuidString)", isDirectory: true)
        storage = PackageStorage(rootURL: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testStandardBackendSelectionPrioritizesTrollStoreDocumentImportWithoutClaimingInstallation() async {
        let coordinator = await makeCoordinator(backends: InstallationBackendCatalog.standard)
        await coordinator.refreshBackendOptions()

        let available = await MainActor.run { coordinator.availableBackendOptions }
        XCTAssertEqual(available.map(\.identifier), ["trollstore", "external-handoff"])
        let automaticBackend = await MainActor.run { coordinator.automaticBackendIdentifier() }
        XCTAssertEqual(automaticBackend, "trollstore")
        XCTAssertFalse(available.contains { $0.capabilities.contains(.confirmedInstall) })
    }

    func testAvailabilityStatesAreExplicitForTrollStoreSigningAndLite() {
        let trollStore = TrollStoreBackend()
        let lite = TrollStoreLiteBackend()
        let signing = DeveloperSigningBackend()
        guard case .available = trollStore.availability,
              case .unsupported(let liteReason) = lite.availability,
              case .requiresConfiguration(let signingReason) = signing.availability else {
            return XCTFail("Expected an available document-import route and explicit Lite/signing limitations.")
        }
        XCTAssertTrue(liteReason.contains("privileged helper"))
        XCTAssertTrue(signingReason.contains("does not collect or upload Apple credentials"))
    }

    func testTrollStoreBackendRequestsDocumentHandoffOnlyForVerifiedIPA() async throws {
        let package = try makeVerifiedPackage()
        let result = await TrollStoreBackend().install(package: package)
        guard case .handoffRequested = result else {
            return XCTFail("A verified IPA should enter the system document handoff, not report an installation.")
        }
        XCTAssertTrue(TrollStoreBackend().capabilities.contains(.externalHandoff))
        XCTAssertFalse(TrollStoreBackend().capabilities.contains(.confirmedInstall))
        XCTAssertFalse(TrollStoreBackend().capabilities.contains(.inventory))
        XCTAssertFalse(TrollStoreBackend().capabilities.contains(.uninstall))
    }

    func testTrollStoreImportRecognizesOnlyUpstreamDocumentHandlerBundleIdentifiers() {
        XCTAssertEqual(TrollStoreImportTarget.displayName(for: "com.opa334.TrollStore"), "TrollStore")
        XCTAssertEqual(TrollStoreImportTarget.displayName(for: "com.opa334.TrollStoreLite"), "TrollStore Lite")
        XCTAssertNil(TrollStoreImportTarget.displayName(for: "com.example.otherIPAHandler"))
        XCTAssertEqual(TrollStoreImportTarget.ipaContentTypeIdentifier, "com.apple.itunes.ipa")
    }

    func testTrollStoreImportCoordinatorRecordsHandoffNotInstalled() async throws {
        let package = try makeVerifiedPackage()
        let defaults = UserDefaults(suiteName: "DreyzeStoreTrollStoreImport-\(UUID().uuidString)")!
        let history = await MainActor.run { InstallationHistoryStore(defaults: defaults) }
        let coordinator = await MainActor.run {
            InstallationCoordinator(storage: storage, backends: [TrollStoreBackend()], historyStore: history)
        }

        await coordinator.beginInstall(package: package, backendIdentifier: TrollStoreBackend().identifier)
        let pendingState = await MainActor.run { coordinator.state }
        let pendingBackend = await MainActor.run { coordinator.pendingHandoffBackendIdentifier }
        XCTAssertEqual(pendingState, .awaitingHandoff)
        XCTAssertEqual(pendingBackend, "trollstore")
        await MainActor.run {
            coordinator.completeExternalHandoff(
                completed: true,
                destination: TrollStoreImportTarget.trollStoreBundleIdentifier,
                error: nil
            )
        }

        guard case .handedOff(let receipt) = await MainActor.run(body: { coordinator.state }) else {
            return XCTFail("The documented document import must be recorded as a handoff only.")
        }
        XCTAssertEqual(receipt.method, "TrollStore")
        XCTAssertEqual(receipt.destination, TrollStoreImportTarget.trollStoreBundleIdentifier)
        let transitions = await MainActor.run { coordinator.stateHistory }
        XCTAssertFalse(transitions.contains { if case .installed = $0 { true } else { false } })
    }

    func testTrollStoreLiteImportIsRecordedAsHandoffNotInstall() async throws {
        let package = try makeVerifiedPackage()
        let coordinator = await makeCoordinator(backends: [TrollStoreBackend()])

        await coordinator.beginInstall(package: package, backendIdentifier: TrollStoreBackend().identifier)
        await MainActor.run {
            coordinator.completeExternalHandoff(
                completed: true,
                destination: TrollStoreImportTarget.trollStoreLiteBundleIdentifier,
                error: nil
            )
        }

        let result = await MainActor.run { coordinator.state }
        guard case .handedOff(let receipt) = result else {
            return XCTFail("TrollStore Lite receiving the verified IPA must remain a handoff result.")
        }
        XCTAssertEqual(receipt.method, "TrollStore Lite")
        let transitions = await MainActor.run { coordinator.stateHistory }
        XCTAssertFalse(transitions.contains {
            if case .installed = $0 { true } else { false }
        })
    }

    func testUnavailableConfiguredAndUnsupportedBackendsCannotRunInstall() async throws {
        let package = try makeVerifiedPackage()
        let cases: [(BackendAvailability, InstallationFailureCode)] = [
            (.unavailable(reason: "No handoff target."), .backendUnavailable),
            (.requiresConfiguration(reason: "Local signing setup is missing."), .signingRequired),
            (.unsupported(reason: "This environment is not supported."), .unsupportedOS)
        ]

        for (index, item) in cases.enumerated() {
            let backend = RecordingInstallationBackend(identifier: "unavailable-\(index)", availability: item.0, capabilities: [.confirmedInstall], directive: .cancelled)
            let coordinator = await makeCoordinator(backends: [backend])
            await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)
            let state = await MainActor.run { coordinator.state }
            switch state {
            case .failed(let failure), .unsupported(let failure): XCTAssertEqual(failure.code, item.1)
            default: XCTFail("Backend availability \(item.0) unexpectedly advanced to \(state).")
            }
            XCTAssertEqual(backend.installCallCount, 0)
        }
    }

    func testModifiedPackageIsRejectedBeforeBackendReceivesIt() async throws {
        let package = try makeVerifiedPackage()
        try Data(repeating: 0x41, count: Int(package.size)).write(to: package.localURL, options: .atomic)
        let backend = RecordingInstallationBackend(identifier: "recording", availability: .available, capabilities: [.externalHandoff], directive: .handoffRequested)
        let coordinator = await makeCoordinator(backends: [backend])

        await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)

        let state = await MainActor.run { coordinator.state }
        guard case .failed(let failure) = state else { return XCTFail("Expected modified package rejection, got \(state).") }
        XCTAssertEqual(failure.code, .packageRejected)
        XCTAssertEqual(backend.installCallCount, 0)
    }

    func testPackageFromAnotherStorageIsRejected() async throws {
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DreyzeStoreOtherPackage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let otherStorage = PackageStorage(rootURL: otherRoot)
        let package = try makeVerifiedPackage(in: otherStorage)
        let backend = RecordingInstallationBackend(identifier: "recording", availability: .available, capabilities: [.externalHandoff], directive: .handoffRequested)
        let coordinator = await makeCoordinator(backends: [backend])

        await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)

        guard case .failed(let failure) = await MainActor.run(body: { coordinator.state }) else {
            return XCTFail("A package outside this coordinator's PackageStorage must be rejected.")
        }
        XCTAssertEqual(failure.code, .packageRejected)
        XCTAssertEqual(backend.installCallCount, 0)
    }

    func testSuccessfulExternalHandoffIsNeverReportedAsInstalled() async throws {
        let package = try makeVerifiedPackage()
        let backend = RecordingInstallationBackend(identifier: "external-handoff", availability: .available, capabilities: [.externalHandoff], directive: .handoffRequested)
        let defaults = UserDefaults(suiteName: "DreyzeStoreInstallation-\(UUID().uuidString)")!
        let history = await MainActor.run { InstallationHistoryStore(defaults: defaults) }
        let coordinator = await MainActor.run { InstallationCoordinator(storage: storage, backends: [backend], historyStore: history) }

        await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)
        let pendingState = await MainActor.run { coordinator.state }
        XCTAssertEqual(pendingState, .awaitingHandoff)
        await MainActor.run {
            coordinator.completeExternalHandoff(completed: true, destination: "com.apple.DocumentsApp", error: nil)
        }

        let finalState = await MainActor.run { coordinator.state }
        guard case .handedOff(let receipt) = finalState else { return XCTFail("Expected handedOff, got \(finalState).") }
        XCTAssertEqual(receipt.destination, "com.apple.DocumentsApp")
        XCTAssertEqual(receipt.bundleIdentifier, package.bundleIdentifier)
        let historyName = await MainActor.run { history.handedOffPackages.first?.name }
        let transitions = await MainActor.run { coordinator.stateHistory }
        XCTAssertEqual(historyName, "Dreyze Sample")
        XCTAssertTrue(transitions.contains(.preparingInstallation))
        XCTAssertTrue(transitions.contains(.installing))
        XCTAssertFalse(transitions.contains { if case .installed = $0 { true } else { false } })
    }

    func testCancelledHandoffDoesNotCreateInstalledOrHandedOffRecord() async throws {
        let package = try makeVerifiedPackage()
        let backend = RecordingInstallationBackend(identifier: "external-handoff", availability: .available, capabilities: [.externalHandoff], directive: .handoffRequested)
        let defaults = UserDefaults(suiteName: "DreyzeStoreInstallation-\(UUID().uuidString)")!
        let history = await MainActor.run { InstallationHistoryStore(defaults: defaults) }
        let coordinator = await MainActor.run { InstallationCoordinator(storage: storage, backends: [backend], historyStore: history) }

        await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)
        await MainActor.run { coordinator.completeExternalHandoff(completed: false, destination: nil, error: nil) }

        let finalState = await MainActor.run { coordinator.state }
        let historyIsEmpty = await MainActor.run { history.handedOffPackages.isEmpty }
        XCTAssertEqual(finalState, .cancelled)
        XCTAssertTrue(historyIsEmpty)
    }

    func testHandoffFailureIsReportedAsFailed() async throws {
        let package = try makeVerifiedPackage()
        let backend = RecordingInstallationBackend(identifier: "external-handoff", availability: .available, capabilities: [.externalHandoff], directive: .handoffRequested)
        let coordinator = await makeCoordinator(backends: [backend])
        await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)
        let error = NSError(domain: "TestShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "share failed"])

        await MainActor.run { coordinator.completeExternalHandoff(completed: false, destination: nil, error: error) }

        guard case .failed(let failure) = await MainActor.run(body: { coordinator.state }) else {
            return XCTFail("Expected handoff failure.")
        }
        XCTAssertEqual(failure.code, .installationFailed)
    }

    func testConfirmedInstallRequiresExplicitBackendCapability() async throws {
        let package = try makeVerifiedPackage()
        let app = InstalledApplication(bundleIdentifier: package.bundleIdentifier, version: package.version, sourceIdentifier: package.sourceIdentifier, installedAt: Date())
        let backend = RecordingInstallationBackend(identifier: "incorrect", availability: .available, capabilities: [], directive: .installed(app))
        let coordinator = await makeCoordinator(backends: [backend])

        await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)

        guard case .failed(let failure) = await MainActor.run(body: { coordinator.state }) else {
            return XCTFail("A backend without confirmation capability must not produce Installed.")
        }
        XCTAssertEqual(failure.code, .installationUnconfirmed)
    }

    func testConfirmedInstallStateCanOnlyComeFromConfirmingBackend() async throws {
        let package = try makeVerifiedPackage()
        let app = InstalledApplication(bundleIdentifier: package.bundleIdentifier, version: package.version, sourceIdentifier: package.sourceIdentifier, installedAt: Date())
        let backend = RecordingInstallationBackend(identifier: "confirmed", availability: .available, capabilities: [.confirmedInstall, .installedState, .inventory, .uninstall], directive: .installed(app), installedState: .installed(app))
        let coordinator = await makeCoordinator(backends: [backend])

        await coordinator.beginInstall(package: package, backendIdentifier: backend.identifier)

        let installState = await MainActor.run { coordinator.state }
        let inventory = await coordinator.queryInstalledState(bundleIdentifier: package.bundleIdentifier, using: backend.identifier)
        XCTAssertEqual(installState, .installed(app))
        XCTAssertEqual(inventory, .installed(app))
        let uninstall = await coordinator.uninstall(bundleIdentifier: package.bundleIdentifier, using: backend.identifier)
        XCTAssertEqual(uninstall, .uninstalled)
        XCTAssertEqual(backend.uninstallCallCount, 1)
    }

    func testStandardHandoffHasNoInventoryOrUninstallCapability() async {
        let coordinator = await makeCoordinator(backends: [ExternalInstallerBackend()])
        let inventory = await coordinator.queryInstalledState(bundleIdentifier: "org.dreyzestore.sample", using: "external-handoff")
        let uninstall = await coordinator.uninstall(bundleIdentifier: "org.dreyzestore.sample", using: "external-handoff")
        guard case .unsupported = inventory else { return XCTFail("A share handoff cannot query installed applications.") }
        guard case .unsupported = uninstall else { return XCTFail("A share handoff cannot uninstall applications.") }
    }

    private func makeCoordinator(backends: [any InstallationBackend]) async -> InstallationCoordinator {
        let defaults = UserDefaults(suiteName: "DreyzeStoreInstallation-\(UUID().uuidString)")!
        let history = await MainActor.run { InstallationHistoryStore(defaults: defaults) }
        return await MainActor.run { InstallationCoordinator(storage: storage, backends: backends, historyStore: history) }
    }

    private func makeVerifiedPackage(in targetStorage: PackageStorage? = nil) throws -> VerifiedPackage {
        let packageStorage = targetStorage ?? storage!
        let bytes = try makeIPAFixture()
        let intent = try makeIntent(bytes: bytes, using: packageStorage)
        let temporaryURL = packageStorage.temporaryURL(for: intent.id)
        try bytes.write(to: temporaryURL, options: .atomic)
        return try PackageValidator(storage: packageStorage).verifyDownloadedPackage(at: temporaryURL, intent: intent)
    }

    private func makeIntent(bytes: Data, using targetStorage: PackageStorage) throws -> PackageDownloadIntent {
        let release = PackageDownloadRelease(
            appID: "sample-app", name: "Dreyze Sample", developer: "Dreyze Labs",
            bundleIdentifier: "org.dreyzestore.sample", version: "2.1.0", build: "210", minimumOSVersion: "16.0",
            downloadURL: URL(string: "https://packages.example.invalid/sample.ipa")!,
            sha256: SHA256TestHelper.digest(bytes), size: Int64(bytes.count),
            sourceIdentifier: "com.dreyzestore.official", sourceName: "DreyzeStore",
            iconURL: URL(string: "https://assets.example.invalid/sample.png")!
        )
        let intent = PackageDownloadIntent(id: UUID(), release: release, createdAt: Date())
        try targetStorage.save(intent: intent)
        return intent
    }

    private func makeIPAFixture() throws -> Data {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DreyzeStoreIPAFixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let archiveURL = fixtureRoot.appendingPathComponent("sample.ipa")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let infoURL = fixtureRoot.appendingPathComponent("Info.plist")
        let plist: [String: String] = [
            "CFBundleIdentifier": "org.dreyzestore.sample",
            "CFBundleExecutable": "DreyzeSample",
            "CFBundleShortVersionString": "2.1.0",
            "CFBundleVersion": "210",
            "MinimumOSVersion": "16.0"
        ]
        let info = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try info.write(to: infoURL)
        let executableURL = fixtureRoot.appendingPathComponent("DreyzeSample")
        try Data("generated test executable".utf8).write(to: executableURL)
        try archive.addEntry(with: "Payload/DreyzeSample.app/Info.plist", fileURL: infoURL)
        try archive.addEntry(with: "Payload/DreyzeSample.app/DreyzeSample", fileURL: executableURL)
        return try Data(contentsOf: archiveURL)
    }
}

private final class RecordingInstallationBackend: InstallationBackend, @unchecked Sendable {
    let identifier: String
    let displayName: String
    let availability: BackendAvailability
    let capabilities: InstallationCapabilities
    private let directive: InstallationDirective
    private let configuredInstalledState: InstalledState
    private let lock = NSLock()
    private var calls = 0
    private var uninstalls = 0

    init(
        identifier: String,
        availability: BackendAvailability,
        capabilities: InstallationCapabilities,
        directive: InstallationDirective,
        installedState: InstalledState = .unavailable(reason: "Not configured")
    ) {
        self.identifier = identifier
        self.displayName = identifier
        self.availability = availability
        self.capabilities = capabilities
        self.directive = directive
        self.configuredInstalledState = installedState
    }

    var installCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var uninstallCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return uninstalls
    }

    func install(package: VerifiedPackage) async -> InstallationDirective {
        incrementCallCount()
        return directive
    }

    func uninstall(bundleIdentifier: String) async -> UninstallationResult {
        incrementUninstallCount()
        return .uninstalled
    }
    func queryInstalledState(bundleIdentifier: String) async -> InstalledState { configuredInstalledState }

    private func incrementCallCount() {
        lock.lock(); defer { lock.unlock() }
        calls += 1
    }

    private func incrementUninstallCount() {
        lock.lock(); defer { lock.unlock() }
        uninstalls += 1
    }
}

private enum SHA256TestHelper {
    static func digest(_ data: Data) -> String {
        importCryptoKitDigest(data)
    }

    private static func importCryptoKitDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
