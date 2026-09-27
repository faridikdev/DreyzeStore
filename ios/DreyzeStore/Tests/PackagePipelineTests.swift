import CryptoKit
import Foundation
import Network
import XCTest
import ZIPFoundation
@testable import DreyzeStore

final class PackagePipelineTests: XCTestCase {
    private var root: URL!
    private var storage: PackageStorage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DreyzeStorePackageTests-\(UUID().uuidString)", isDirectory: true)
        storage = PackageStorage(rootURL: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testValidGeneratedFixtureCreatesOnlyVerifiedPackageAfterAllStages() async throws {
        let bytes = try makeIPAFixture()
        let transport = TestPackageTransport(action: .success(bytes))
        let app = makeApp(url: URL(string: "https://packages.example.invalid/sample.ipa")!, bytes: bytes)
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport) }

        await MainActor.run { manager.start(app: app) }
        let state = await waitForTerminalState(manager, app: app)

        guard case .ready(let package) = state else { return XCTFail("Expected a verified package, got \(state)") }
        XCTAssertEqual(package.bundleIdentifier, "org.dreyzestore.sample")
        XCTAssertEqual(package.version, "2.1.0")
        XCTAssertEqual(package.build, "210")
        XCTAssertEqual(package.size, Int64(bytes.count))
        XCTAssertEqual(package.sha256, Self.sha256(bytes))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.localURL.path))
        let savedPackages = await MainActor.run { manager.packages }
        XCTAssertEqual(savedPackages.count, 1)

        let history = await MainActor.run { manager.stateHistory[PackageDownloadRelease(app: app).deduplicationKey] ?? [] }
        XCTAssertTrue(history.contains { if case .preparing = $0 { return true }; return false })
        XCTAssertTrue(history.contains { if case .downloading = $0 { return true }; return false })
        XCTAssertTrue(history.contains { if case .verifying = $0 { return true }; return false })
        XCTAssertTrue(history.contains { if case .inspecting = $0 { return true }; return false })
        XCTAssertTrue(history.contains { if case .ready = $0 { return true }; return false })
        XCTAssertTrue(storage.pendingIntents().isEmpty)
    }

    func testCancellationRemovesTemporaryPackageAndReportsCancelled() async throws {
        let bytes = try makeIPAFixture()
        let transport = TestPackageTransport(action: .wait)
        let app = makeApp(url: URL(string: "https://packages.example.invalid/sample.ipa")!, bytes: bytes)
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport) }
        await MainActor.run { manager.start(app: app) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await MainActor.run { manager.cancel(app: app) }

        let state = await waitForTerminalState(manager, app: app)
        XCTAssertEqual(state, .cancelled)
        XCTAssertTrue(storage.verifiedPackages().isEmpty)
        XCTAssertTrue(storage.pendingIntents().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.temporaryURL(for: transport.lastTransferID ?? UUID()).path))
    }

    func testRetryStartsFreshAttemptAfterNetworkFailure() async throws {
        let bytes = try makeIPAFixture()
        let transport = TestPackageTransport(action: .failFirstThenSucceed(bytes))
        let app = makeApp(url: URL(string: "https://packages.example.invalid/sample.ipa")!, bytes: bytes)
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport) }

        await MainActor.run { manager.start(app: app) }
        let first = await waitForTerminalState(manager, app: app)
        guard case .failed(let failure) = first else { return XCTFail("Expected first attempt to fail") }
        XCTAssertEqual(failure.code, .network)

        await MainActor.run { manager.retry(app: app) }
        let second = await waitForTerminalState(manager, app: app)
        guard case .ready = second else { return XCTFail("Expected retry to produce a verified package") }
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testDuplicateReleaseDownloadIsPrevented() async throws {
        let bytes = try makeIPAFixture()
        let transport = TestPackageTransport(action: .wait)
        let app = makeApp(url: URL(string: "https://packages.example.invalid/sample.ipa")!, bytes: bytes)
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport) }

        await MainActor.run {
            manager.start(app: app)
            manager.start(app: app)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(transport.requestCount, 1)
        await MainActor.run { manager.cancel(app: app) }
        _ = await waitForTerminalState(manager, app: app)
    }

    func testOnlyHTTPSIsAllowedOutsideExplicitLoopbackTestPolicy() throws {
        XCTAssertTrue(DownloadURLPolicy.httpsOnly.allows(URL(string: "https://packages.example.test/a.ipa")))
        for value in ["http://packages.example.test/a.ipa", "file:///tmp/a.ipa", "ftp://example.test/a.ipa", "data:application/octet-stream,abc", "javascript:alert(1)"] {
            XCTAssertFalse(DownloadURLPolicy.httpsOnly.allows(URL(string: value)), value)
        }
        XCTAssertTrue(DownloadURLPolicy.loopbackHTTPForTests.allows(URL(string: "http://127.0.0.1:9000/a.ipa")))
        XCTAssertFalse(DownloadURLPolicy.loopbackHTTPForTests.allows(URL(string: "http://example.test/a.ipa")))
        XCTAssertFalse(DownloadURLPolicy.httpsOnly.allows(URL(string: "https://user:password@example.test/a.ipa")))
    }

    func testChecksumSucceedsForLocalTemporaryFile() throws {
        let bytes = try makeIPAFixture()
        let intent = try makeIntent(bytes: bytes)
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)

        let digest = try PackageValidator(storage: storage).verifyChecksum(at: file, intent: intent)

        XCTAssertEqual(digest.size, Int64(bytes.count))
        XCTAssertEqual(digest.sha256, Self.sha256(bytes))
    }

    func testChecksumMismatchFailsBeforeArchiveInspection() throws {
        let bytes = try makeIPAFixture()
        let intent = try makeIntent(bytes: bytes, sha256: String(repeating: "0", count: 64))
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)

        XCTAssertThrowsError(try PackageValidator(storage: storage).verifyChecksum(at: file, intent: intent)) { error in
            XCTAssertEqual((error as? PackageDownloadFailure)?.code, .checksumMismatch)
        }
    }

    func testChecksumMismatchNeverCreatesVerifiedPackageAndCleansTheDownload() async throws {
        let bytes = try makeIPAFixture()
        let app = makeApp(url: URL(string: "https://packages.example.invalid/sample.ipa")!, bytes: bytes, sha256: String(repeating: "0", count: 64))
        let transport = TestPackageTransport(action: .success(bytes))
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport) }
        await MainActor.run { manager.start(app: app) }

        let state = await waitForTerminalState(manager, app: app)
        guard case .failed(let failure) = state else { return XCTFail("Expected checksum failure") }
        XCTAssertEqual(failure.code, .checksumMismatch)
        XCTAssertTrue(storage.verifiedPackages().isEmpty)
        XCTAssertTrue(storage.pendingIntents().isEmpty)
        let transferID = try XCTUnwrap(transport.lastTransferID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.temporaryURL(for: transferID).path))
    }

    func testDeclaredPackageSizeMustMatchActualBytes() throws {
        let bytes = try makeIPAFixture()
        let intent = try makeIntent(bytes: bytes, declaredSize: Int64(bytes.count + 1))
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)

        XCTAssertThrowsError(try PackageValidator(storage: storage).verifyChecksum(at: file, intent: intent)) { error in
            XCTAssertEqual((error as? PackageDownloadFailure)?.code, .sizeMismatch)
        }
    }

    func testMalformedZipIsRejected() throws {
        try assertArchiveRejected(Data("not a ZIP archive".utf8), expected: .invalidArchive)
    }

    func testMissingPayloadIsRejected() throws {
        try assertArchiveRejected(makeArchive([("Other/Example.app/Info.plist", try infoPlist()), ("Other/Example.app/Example", Data("exec".utf8))]), expected: .missingPayload)
    }

    func testMissingInfoPlistIsRejected() throws {
        try assertArchiveRejected(makeArchive([("Payload/Example.app/Example", Data("exec".utf8))]), expected: .missingInfoPlist)
    }

    func testMalformedInfoPlistIsRejected() throws {
        let bytes = try makeArchive([
            ("Payload/DreyzeSample.app/Info.plist", Data("not a property list".utf8)),
            ("Payload/DreyzeSample.app/DreyzeSample", Data("exec".utf8))
        ])
        try assertArchiveRejected(bytes, expected: .malformedMetadata)
    }

    func testMissingExecutableEntryIsRejected() throws {
        let bytes = try makeArchive([("Payload/DreyzeSample.app/Info.plist", try infoPlist())])
        try assertArchiveRejected(bytes, expected: .missingExecutable)
    }

    func testPathTraversalIsRejected() throws {
        let archive = try makeIPAFixture()
        let malicious = Self.replacingBytes(in: archive, from: "Payload", to: "../AAAA")
        try assertArchiveRejected(malicious, expected: .unsafeArchive)
    }

    func testAbsoluteArchivePathIsRejected() throws {
        let archive = try makeIPAFixture()
        let malicious = Self.replacingBytes(in: archive, from: "Payload", to: "/AAAAAA")
        try assertArchiveRejected(malicious, expected: .unsafeArchive)
    }

    func testSymlinkEscapeIsRejected() throws {
        let linkSource = root.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(atPath: linkSource.path, withDestinationPath: "../../outside")
        let archiveData = try makeArchive([
            ("Payload/DreyzeSample.app/Info.plist", try infoPlist()),
            ("Payload/DreyzeSample.app/DreyzeSample", Data("executable".utf8))
        ])
        let archiveURL = root.appendingPathComponent("symlink-fixture.zip")
        try archiveData.write(to: archiveURL)
        let writableArchive = try Archive(url: archiveURL, accessMode: .update)
        try writableArchive.addEntry(with: "Payload/DreyzeSample.app/escape", fileURL: linkSource)
        let archive = try Data(contentsOf: archiveURL)
        try assertArchiveRejected(archive, expected: .unsafeArchive)
    }

    func testCompressionRatioLimitRejectsZipBombFixture() throws {
        let repeated = Data(repeating: 0x41, count: 256 * 1_024)
        let bytes = try makeIPAFixture(extraEntries: [("Payload/DreyzeSample.app/large.dat", repeated)])
        let intent = try makeIntent(bytes: bytes)
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)
        var limits = PackageValidationLimits()
        limits.maximumCompressionRatio = 2

        XCTAssertThrowsError(try PackageValidator(storage: storage, limits: limits).verifyDownloadedPackage(at: file, intent: intent)) { error in
            XCTAssertEqual(error as? PackageVerificationError, .unsafeArchive)
        }
    }

    func testArchiveEntryCountLimitIsEnforced() throws {
        let bytes = try makeIPAFixture(extraEntries: [("Payload/DreyzeSample.app/readme.txt", Data("sample".utf8))])
        let intent = try makeIntent(bytes: bytes)
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)
        var limits = PackageValidationLimits()
        limits.maximumEntries = 2

        XCTAssertThrowsError(try PackageValidator(storage: storage, limits: limits).verifyDownloadedPackage(at: file, intent: intent)) { error in
            XCTAssertEqual(error as? PackageVerificationError, .unsafeArchive)
        }
    }

    func testCentralDirectoryByteLimitIsEnforced() throws {
        let bytes = try makeIPAFixture()
        let intent = try makeIntent(bytes: bytes)
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)
        var limits = PackageValidationLimits()
        limits.maximumCentralDirectoryBytes = 1

        XCTAssertThrowsError(try PackageValidator(storage: storage, limits: limits).verifyDownloadedPackage(at: file, intent: intent)) { error in
            XCTAssertEqual(error as? PackageVerificationError, .unsafeArchive)
        }
    }

    func testExcessiveArchivePathDepthIsRejected() throws {
        let path = "Payload/DreyzeSample.app/" + Array(repeating: "nested", count: 70).joined(separator: "/")
        let bytes = try makeIPAFixture(extraEntries: [(path, Data("nested".utf8))])
        let intent = try makeIntent(bytes: bytes)
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)
        var limits = PackageValidationLimits()
        limits.maximumPathDepth = 16

        XCTAssertThrowsError(try PackageValidator(storage: storage, limits: limits).verifyDownloadedPackage(at: file, intent: intent)) { error in
            XCTAssertEqual(error as? PackageVerificationError, .unsafeArchive)
        }
    }

    func testBundleVersionBuildAndMinimumOSMustMatchRelease() throws {
        let bytes = try makeIPAFixture(version: "1.0.0")
        let intent = try makeIntent(bytes: bytes, version: "2.1.0")
        let file = storage.temporaryURL(for: intent.id)
        try bytes.write(to: file)

        XCTAssertThrowsError(try PackageValidator(storage: storage).verifyDownloadedPackage(at: file, intent: intent)) { error in
            XCTAssertEqual((error as? PackageDownloadFailure)?.code, .invalidMetadata)
        }
        XCTAssertTrue(storage.verifiedPackages().isEmpty)
    }

    func testCleanupRemovesOnlyOldInactiveManagedTemporaryFiles() throws {
        let oldID = UUID()
        let activeID = UUID()
        try Data("old".utf8).write(to: storage.temporaryURL(for: oldID))
        try Data("active".utf8).write(to: storage.temporaryURL(for: activeID))
        let oldDate = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: storage.temporaryURL(for: oldID).path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: storage.temporaryURL(for: activeID).path)

        let removedBytes = try storage.cleanTemporaryFiles(preserving: [activeID], olderThan: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(removedBytes, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.temporaryURL(for: oldID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.temporaryURL(for: activeID).path))
    }

    func testOrphanedVerifiedPackageIsRemovedWithoutTouchingAdjacentFiles() throws {
        let verifiedDirectory = root.appendingPathComponent("Verified", isDirectory: true)
        let orphanID = UUID().uuidString.lowercased()
        let orphanURL = verifiedDirectory.appendingPathComponent(orphanID).appendingPathExtension("ipa")
        let unrelatedURL = verifiedDirectory.appendingPathComponent("readme.txt")
        try Data("orphan".utf8).write(to: orphanURL)
        try Data("leave me".utf8).write(to: unrelatedURL)

        XCTAssertEqual(try storage.cleanOrphanedVerifiedPackages(), 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testLocalHTTPDownloadRunsThroughHashArchiveAndMetadataPipeline() async throws {
        let bytes = try makeIPAFixture()
        let server = try LoopbackHTTPServer(status: 200, body: bytes)
        let url = try await server.start()
        let transport = URLSessionPackageDownloadTransport(storage: storage, mode: .foregroundForTests, urlPolicy: .loopbackHTTPForTests)
        let app = makeApp(url: url, bytes: bytes)
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport, urlPolicy: .loopbackHTTPForTests) }

        await MainActor.run { manager.start(app: app) }
        let state = await waitForTerminalState(manager, app: app)
        guard case .ready(let package) = state else { return XCTFail("Local HTTP pipeline failed: \(state)") }
        XCTAssertEqual(package.sha256, Self.sha256(bytes))
        XCTAssertEqual(package.bundleIdentifier, "org.dreyzestore.sample")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.localURL.path))
        server.stop()
    }

    func testLocalHTTPServerErrorIsReportedWithoutKeepingTemporaryPackage() async throws {
        let body = Data("upstream unavailable".utf8)
        let server = try LoopbackHTTPServer(status: 503, body: body)
        let url = try await server.start()
        let transport = URLSessionPackageDownloadTransport(storage: storage, mode: .foregroundForTests, urlPolicy: .loopbackHTTPForTests)
        let app = makeApp(url: url, bytes: body)
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport, urlPolicy: .loopbackHTTPForTests) }

        await MainActor.run { manager.start(app: app) }
        let state = await waitForTerminalState(manager, app: app)
        guard case .failed(let failure) = state else { return XCTFail("Expected HTTP failure") }
        XCTAssertEqual(failure.code, .http)
        XCTAssertEqual(failure.httpStatus, 503)
        XCTAssertTrue(storage.verifiedPackages().isEmpty)
        XCTAssertTrue(storage.pendingIntents().isEmpty)
        server.stop()
    }

    func testLocalHTTPOversizedDownloadIsCancelledAtDeclaredLimit() async throws {
        let bytes = try makeIPAFixture()
        let server = try LoopbackHTTPServer(status: 200, body: bytes)
        let url = try await server.start()
        let transport = URLSessionPackageDownloadTransport(storage: storage, mode: .foregroundForTests, urlPolicy: .loopbackHTTPForTests)
        let app = makeApp(url: url, bytes: bytes, declaredSize: Int64(bytes.count - 1))
        let manager = await MainActor.run { DownloadManager(storage: storage, transport: transport, urlPolicy: .loopbackHTTPForTests) }

        await MainActor.run { manager.start(app: app) }
        let state = await waitForTerminalState(manager, app: app)
        guard case .failed(let failure) = state else { return XCTFail("Expected size limit failure") }
        XCTAssertEqual(failure.code, .sizeLimit)
        XCTAssertTrue(storage.verifiedPackages().isEmpty)
        server.stop()
    }

    private func assertArchiveRejected(_ bytes: Data, expected: PackageVerificationError, file: StaticString = #filePath, line: UInt = #line) throws {
        let intent = try makeIntent(bytes: bytes)
        let fileURL = storage.temporaryURL(for: intent.id)
        try bytes.write(to: fileURL)
        XCTAssertThrowsError(try PackageValidator(storage: storage).verifyDownloadedPackage(at: fileURL, intent: intent), file: file, line: line) { error in
            XCTAssertEqual(error as? PackageVerificationError, expected, file: file, line: line)
        }
        XCTAssertTrue(storage.verifiedPackages().isEmpty)
    }

    private func makeIntent(bytes: Data, sha256: String? = nil, declaredSize: Int64? = nil, version: String = "2.1.0") throws -> PackageDownloadIntent {
        let release = PackageDownloadRelease(
            appID: "sample-app", name: "Dreyze Sample", developer: "Dreyze Labs",
            bundleIdentifier: "org.dreyzestore.sample", version: version, build: "210", minimumOSVersion: "16.0",
            downloadURL: URL(string: "https://packages.example.invalid/sample.ipa")!,
            sha256: sha256 ?? Self.sha256(bytes), size: declaredSize ?? Int64(bytes.count),
            sourceIdentifier: "com.dreyzestore.official", sourceName: "DreyzeStore",
            iconURL: URL(string: "https://assets.example.invalid/sample.png")!
        )
        let intent = PackageDownloadIntent(id: UUID(), release: release, createdAt: Date())
        try storage.save(intent: intent)
        return intent
    }

    private func makeApp(url: URL, bytes: Data, declaredSize: Int64? = nil, sha256: String? = nil) -> StoreApp {
        StoreApp(
            id: "sample-app", bundleIdentifier: "org.dreyzestore.sample", name: "Dreyze Sample", shortDescription: "Generated test fixture.",
            developer: Developer(id: "dreyze-labs", name: "Dreyze Labs", websiteURL: nil),
            category: StoreCategory(id: "utilities", name: "Utilities", appCount: 1),
            iconURL: URL(string: "https://assets.example.invalid/sample.png")!,
            currentVersion: AppVersion(id: "release-210", version: "2.1.0", build: "210", versionDate: Date(), minimumOSVersion: "16.0", downloadURL: url, sha256: sha256 ?? Self.sha256(bytes), size: declaredSize ?? Int64(bytes.count), releaseNotes: "Test-only generated package.", channel: "stable"),
            repositoryIdentifier: "com.dreyzestore.official", repositoryName: "DreyzeStore",
            description: "Runtime-generated non-installable test fixture.", screenshots: nil
        )
    }

    private func makeIPAFixture(version: String = "2.1.0", extraEntries: [(String, Data)] = []) throws -> Data {
        let info = try infoPlist(version: version)
        return try makeArchive([
            ("Payload/DreyzeSample.app/Info.plist", info),
            ("Payload/DreyzeSample.app/DreyzeSample", Data("test executable contents".utf8))
        ] + extraEntries.map { ($0.0, $0.1) })
    }

    private func infoPlist(version: String = "2.1.0") throws -> Data {
        let dictionary: [String: String] = [
            "CFBundleIdentifier": "org.dreyzestore.sample",
            "CFBundleExecutable": "DreyzeSample",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "210",
            "MinimumOSVersion": "16.0"
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    private func makeArchive(_ entries: [(String, Data)]) throws -> Data {
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (index, (path, data)) in entries.enumerated() {
            let source = sources.appendingPathComponent("entry-\(index)-\(UUID().uuidString)")
            try data.write(to: source)
            try archive.addEntry(with: path, fileURL: source, compressionMethod: .deflate)
        }
        return try Data(contentsOf: archiveURL)
    }

    private func makeArchive(_ entries: [(String, URL)]) throws -> Data {
        let archiveURL = root.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (path, source) in entries { try archive.addEntry(with: path, fileURL: source) }
        return try Data(contentsOf: archiveURL)
    }

    private func waitForTerminalState(_ manager: DownloadManager, app: StoreApp) async -> PackageDownloadState {
        for _ in 0..<500 {
            let state = await MainActor.run { manager.state(for: app) }
            switch state {
            case .ready, .failed, .cancelled: return state
            default: try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return await MainActor.run { manager.state(for: app) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func replacingBytes(in data: Data, from: String, to: String) -> Data {
        var bytes = Array(data)
        let needle = Array(from.utf8)
        let replacement = Array(to.utf8)
        guard needle.count == replacement.count else { return data }
        var index = 0
        while index <= bytes.count - needle.count {
            if Array(bytes[index..<(index + needle.count)]) == needle {
                bytes.replaceSubrange(index..<(index + needle.count), with: replacement)
                index += replacement.count
            } else { index += 1 }
        }
        return Data(bytes)
    }
}

private final class TestPackageTransport: PackageDownloadTransport, @unchecked Sendable {
    enum Action { case success(Data), failFirstThenSucceed(Data), failure(PackageDownloadFailure), wait }
    private enum Attempt { case success(Data), failure(PackageDownloadFailure), wait }
    private let lock = NSLock()
    private let action: Action
    private var attempts = 0
    private var lastID: UUID?

    init(action: Action) { self.action = action }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var lastTransferID: UUID? { lock.lock(); defer { lock.unlock() }; return lastID }

    func download(intent: PackageDownloadIntent, destinationURL: URL, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> PackageTransferResponse {
        let attempt = nextAttempt(for: intent.id)
        switch attempt {
        case .failure(let failure): throw failure
        case .wait: try await Task.sleep(nanoseconds: 60_000_000_000); throw PackageDownloadFailure(.cancelled)
        case .success(let bytes):
            try bytes.write(to: destinationURL, options: .atomic)
            onProgress(DownloadProgress(receivedBytes: Int64(bytes.count), expectedBytes: Int64(bytes.count)))
            try await Task.sleep(nanoseconds: 20_000_000)
            return PackageTransferResponse(fileURL: destinationURL, finalURL: intent.release.downloadURL, statusCode: 200, receivedBytes: Int64(bytes.count))
        }
    }

    func cancel(transferID: UUID) { }
    func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) { handler() }

    private func nextAttempt(for id: UUID) -> Attempt {
        lock.lock(); defer { lock.unlock() }
        attempts += 1
        lastID = id
        switch action {
        case .success(let bytes): return .success(bytes)
        case .failFirstThenSucceed(let bytes): return attempts == 1 ? .failure(PackageDownloadFailure(.network)) : .success(bytes)
        case .failure(let failure): return .failure(failure)
        case .wait: return .wait
        }
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dreyzestore.package-test-http")
    private let status: Int
    private let body: Data
    private var readyContinuation: CheckedContinuation<URL, Error>?

    init(status: Int, body: Data) throws {
        self.status = status
        self.body = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else {
                        self.resumeReady(.failure(URLError(.cannotConnectToHost)))
                        return
                    }
                    var components = URLComponents()
                    components.scheme = "http"
                    components.host = "127.0.0.1"
                    components.port = Int(port.rawValue)
                    components.path = "/sample.ipa"
                    guard let url = components.url else {
                        self.resumeReady(.failure(URLError(.badURL)))
                        return
                    }
                    self.resumeReady(.success(url))
                case .failed(let error): self.resumeReady(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            let reason = self.status == 200 ? "OK" : "Service Unavailable"
            let header = "HTTP/1.1 \(self.status) \(reason)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + self.body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func resumeReady(_ result: Result<URL, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(with: result)
    }
}
