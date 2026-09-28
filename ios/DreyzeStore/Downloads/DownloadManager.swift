import Combine
import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager(
        storage: .shared,
        transport: URLSessionPackageDownloadTransport(storage: .shared),
        urlPolicy: .httpsOnly
    )

    @Published private(set) var states: [String: PackageDownloadState] = [:]
    @Published private(set) var packages: [StoredVerifiedPackage] = []
    private(set) var stateHistory: [String: [PackageDownloadState]] = [:]

    let storage: PackageStorage
    private let transport: any PackageDownloadTransport
    private let urlPolicy: DownloadURLPolicy
    private let validator: PackageValidator
    private var activeIDs: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(storage: PackageStorage, transport: any PackageDownloadTransport, urlPolicy: DownloadURLPolicy = .httpsOnly) {
        self.storage = storage
        self.transport = transport
        self.urlPolicy = urlPolicy
        self.validator = PackageValidator(storage: storage)
        try? storage.cleanOrphanedVerifiedPackages()
        self.packages = storage.verifiedPackages()
    }

    func state(for app: StoreApp) -> PackageDownloadState {
        states[PackageDownloadRelease(app: app).deduplicationKey] ?? .idle
    }

    func start(app: StoreApp) {
        let release = PackageDownloadRelease(app: app)
        start(release: release, transferID: UUID())
    }

    func retry(app: StoreApp) {
        let key = PackageDownloadRelease(app: app).deduplicationKey
        if states[key]?.isActive == true { return }
        states[key] = .idle
        start(app: app)
    }

    func downloadAndWait(app: StoreApp) async throws -> VerifiedPackage {
        let key = PackageDownloadRelease(app: app).deduplicationKey
        if case .ready(let package) = states[key] { return package }
        start(app: app)
        do {
            while true {
                try Task.checkCancellation()
                switch states[key] ?? .idle {
                case .ready(let package): return package
                case .failed(let failure): throw failure
                case .cancelled: throw CancellationError()
                default: try await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch is CancellationError {
            cancel(app: app)
            throw CancellationError()
        }
    }

    func prunePreviousPackages(bundleIdentifier: String, keeping package: VerifiedPackage) throws {
        let previous = storage.verifiedPackages().filter {
            $0.bundleIdentifier == bundleIdentifier
                && !($0.version == package.version && $0.build == package.build && $0.sha256 == package.sha256)
        }
        for item in previous { try deletePackage(item) }
    }

    func cancel(app: StoreApp) {
        let key = PackageDownloadRelease(app: app).deduplicationKey
        guard let id = activeIDs.removeValue(forKey: key) else { return }
        tasks[key]?.cancel()
        transport.cancel(transferID: id)
        storage.removeTransferFiles(id)
        setState(.cancelled, for: key)
    }

    func restorePendingDownloads() {
        packages = storage.verifiedPackages()
        for intent in storage.pendingIntents() where activeIDs[ intent.release.deduplicationKey ] == nil {
            start(release: intent.release, transferID: intent.id, restoredIntent: intent)
        }
    }

    func setBackgroundEventsCompletionHandler(identifier: String, handler: @escaping @Sendable () -> Void) {
        guard let transport = transport as? URLSessionPackageDownloadTransport,
              transport.sessionIdentifier == identifier else {
            handler()
            return
        }
        transport.setBackgroundEventsCompletionHandler(handler)
    }

    func refreshPackages() {
        packages = storage.verifiedPackages()
    }

    func deletePackage(_ package: StoredVerifiedPackage) throws {
        try storage.deleteVerifiedPackage(id: package.id)
        packages = storage.verifiedPackages()
        for (key, state) in states where isReady(state) {
            if case .ready(let verified) = state, verified.localURL.deletingPathExtension().lastPathComponent == package.id {
                states[key] = .idle
            }
        }
    }

    func deleteAllDownloadedPackages() throws {
        try storage.deleteAllVerifiedPackages()
        packages = storage.verifiedPackages()
        for (key, state) in states where isReady(state) { states[key] = .idle }
    }

    func cleanTemporaryFiles() throws -> Int64 {
        try storage.cleanTemporaryFiles(preserving: Set(activeIDs.values), olderThan: .distantFuture)
    }

    func storageUsage(cacheBytes: Int64 = 0) -> PackageStorageUsage {
        storage.storageUsage(cacheBytes: cacheBytes)
    }

    private func start(release: PackageDownloadRelease, transferID: UUID, restoredIntent: PackageDownloadIntent? = nil) {
        let key = release.deduplicationKey
        if let current = states[key], current.isActive {
            return
        }
        guard urlPolicy.allows(release.downloadURL) else {
            setState(.failed(PackageDownloadFailure(.insecureURL)), for: key)
            return
        }
        let intent = restoredIntent ?? PackageDownloadIntent(id: transferID, release: release, createdAt: Date())
        do {
            try storage.ensureCapacity(for: release.size)
            if restoredIntent == nil { try storage.save(intent: intent) }
        } catch {
            setState(.failed(Self.failure(for: error)), for: key)
            return
        }

        activeIDs[key] = transferID
        setState(.preparing, for: key)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(intent: intent, key: key)
        }
        tasks[key] = task
    }

    private func perform(intent: PackageDownloadIntent, key: String) async {
        let transferID = intent.id
        defer {
            if activeIDs[key] == transferID { activeIDs.removeValue(forKey: key) }
            tasks.removeValue(forKey: key)
        }
        do {
            setState(.downloading(DownloadProgress(receivedBytes: 0, expectedBytes: intent.release.size)), for: key)
            let response = try await transport.download(intent: intent, destinationURL: storage.temporaryURL(for: transferID)) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.activeIDs[key] == transferID,
                          case .downloading = self.states[key] else { return }
                    self.setState(.downloading(progress), for: key)
                }
            }
            try Task.checkCancellation()
            guard activeIDs[key] == transferID else { return }
            guard response.receivedBytes == intent.release.size else { throw PackageDownloadFailure(.sizeMismatch) }

            setState(.verifying, for: key)
            let checksumTask = Task.detached(priority: .utility) { [validator] in
                try validator.verifyChecksum(at: response.fileURL, intent: intent)
            }
            let digest = try await withTaskCancellationHandler {
                try await checksumTask.value
            } onCancel: {
                checksumTask.cancel()
            }
            try Task.checkCancellation()
            guard activeIDs[key] == transferID else { return }

            setState(.inspecting, for: key)
            let inspectionTask = Task.detached(priority: .utility) { [validator] in
                try validator.inspectAndStore(at: response.fileURL, intent: intent, digest: digest)
            }
            let package = try await withTaskCancellationHandler {
                try await inspectionTask.value
            } onCancel: {
                inspectionTask.cancel()
            }
            guard activeIDs[key] == transferID else { return }
            packages = storage.verifiedPackages()
            setState(.ready(package), for: key)
        } catch is CancellationError {
            storage.removeTransferFiles(transferID)
            if activeIDs[key] == transferID { setState(.cancelled, for: key) }
        } catch {
            storage.removeTransferFiles(transferID)
            if activeIDs[key] == transferID { setState(.failed(Self.failure(for: error)), for: key) }
        }
    }

    private func setState(_ state: PackageDownloadState, for key: String) {
        states[key] = state
        var history = stateHistory[key, default: []]
        history.append(state)
        stateHistory[key] = Array(history.suffix(12))
    }

    private func isReady(_ state: PackageDownloadState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    private static func failure(for error: Error) -> PackageDownloadFailure {
        if let failure = error as? PackageDownloadFailure { return failure }
        if let verification = error as? PackageVerificationError {
            switch verification {
            case .checksumMismatch: return PackageDownloadFailure(.checksumMismatch)
            case .unsafeArchive: return PackageDownloadFailure(.unsafeArchive)
            case .metadataMismatch, .malformedMetadata: return PackageDownloadFailure(.invalidMetadata)
            case .declaredSizeMismatch: return PackageDownloadFailure(.sizeMismatch)
            case .invalidArchive, .missingPayload, .missingApplicationBundle, .missingInfoPlist, .missingExecutable:
                return PackageDownloadFailure(.invalidArchive)
            }
        }
        if error is CancellationError { return PackageDownloadFailure(.cancelled) }
        if PackageStorage.isInsufficientStorage(error) {
            return PackageDownloadFailure(.insufficientStorage)
        }
        if let urlError = error as? URLError {
            return PackageDownloadFailure(urlError.code == .timedOut ? .timeout : (urlError.code == .cancelled ? .cancelled : .network))
        }
        return PackageDownloadFailure(.unknown)
    }
}
