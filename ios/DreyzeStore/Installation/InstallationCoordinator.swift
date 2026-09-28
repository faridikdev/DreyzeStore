import Combine
import Foundation

public typealias InstallationStateObserver = @MainActor (InstallationState) -> Void

@MainActor
public final class InstallationCoordinator: ObservableObject {
    public static let shared = InstallationCoordinator(storage: .shared)

    @Published public private(set) var state: InstallationState = .ready
    public private(set) var stateHistory: [InstallationState] = [.ready]
    @Published public private(set) var backendOptions: [InstallationBackendOption] = []
    @Published public private(set) var pendingHandoffPackage: VerifiedPackage?
    @Published public private(set) var pendingHandoffBackendIdentifier: String?

    private let storage: PackageStorage
    private let validator: PackageValidator
    private let backends: [any InstallationBackend]
    private let historyStore: InstallationHistoryStore
    private var activeOperationID: UUID?
    private var pendingBackend: (any InstallationBackend)?
    private var pendingPackageRecord: StoredVerifiedPackage?
    private var activeInstallationBackend: (any InstallationBackend)?
    private var activeInstallationTask: Task<InstallationDirective, Never>?
    private var stateObserver: InstallationStateObserver?

    init(
        storage: PackageStorage,
        backends: [any InstallationBackend] = InstallationBackendCatalog.standard,
        historyStore: InstallationHistoryStore = .shared
    ) {
        self.storage = storage
        self.validator = PackageValidator(storage: storage)
        self.backends = backends
        self.historyStore = historyStore
    }

    public var availableBackendOptions: [InstallationBackendOption] {
        backendOptions.filter { $0.availability == .available }
    }

    public func refreshBackendOptions() async {
        var options: [InstallationBackendOption] = []
        for backend in backends {
            await backend.refreshAvailability()
            options.append(InstallationBackendOption(
                identifier: backend.identifier,
                displayName: backend.displayName,
                availability: backend.availability,
                capabilities: backend.capabilities
            ))
        }
        backendOptions = options
    }

    public func automaticBackendIdentifier() -> String? {
        availableBackendOptions.first(where: { $0.capabilities.contains(.confirmedInstall) })?.identifier
            ?? availableBackendOptions.first(where: { $0.capabilities.contains(.externalHandoff) })?.identifier
    }

    public func beginInstall(package: VerifiedPackage, backendIdentifier: String?) async {
        guard !state.isActive else { return }
        guard let backendIdentifier,
              let backend = backends.first(where: { $0.identifier == backendIdentifier }) else {
            transition(to: .unsupported(.unavailable("No supported installation method is available for this device.")))
            return
        }

        let operationID = UUID()
        activeOperationID = operationID
        transition(to: .preparingInstallation)
        pendingHandoffPackage = nil
        pendingHandoffBackendIdentifier = nil
        pendingBackend = nil
        pendingPackageRecord = nil

        switch backend.availability {
        case .available:
            break
        case .unavailable(let reason):
            transition(to: .failed(.unavailable(reason)))
            activeOperationID = nil
            return
        case .requiresConfiguration(let reason):
            transition(to: .unsupported(.configurationRequired(reason)))
            activeOperationID = nil
            return
        case .unsupported(let reason):
            transition(to: .unsupported(.unsupported(reason)))
            activeOperationID = nil
            return
        }

        do {
            let validator = self.validator
            let verified = try await Task.detached(priority: .userInitiated) {
                try validator.revalidateForInstallation(package)
            }.value
            guard activeOperationID == operationID else { return }
            transition(to: .installing)

            activeInstallationBackend = backend
            let task = Task { [weak self] in
                await backend.install(package: verified) { [weak self] progress in
                    await self?.report(progress, operationID: operationID)
                }
            }
            activeInstallationTask = task
            let directive = await task.value
            activeInstallationTask = nil
            activeInstallationBackend = nil
            guard activeOperationID == operationID else { return }
            switch directive {
            case .installed(let installed):
                guard backend.capabilities.contains(.confirmedInstall) else {
                    transition(to: .failed(InstallationFailure(
                        code: .installationUnconfirmed,
                        title: "Installation Couldn’t Be Confirmed",
                        userMessage: "This method cannot verify that the app was installed.",
                        technicalDetails: "Backend \(backend.identifier) returned installed without the confirmedInstall capability."
                    )))
                    activeOperationID = nil
                    return
                }
                transition(to: .installed(installed))
                activeOperationID = nil
            case .handoffRequested:
                guard backend.capabilities.contains(.externalHandoff),
                      let record = storage.storedPackage(matching: verified) else {
                    transition(to: .failed(.packageRejected("The handoff backend did not have a managed verified package receipt.")))
                    activeOperationID = nil
                    return
                }
                pendingHandoffPackage = verified
                pendingHandoffBackendIdentifier = backend.identifier
                pendingBackend = backend
                pendingPackageRecord = record
                transition(to: .awaitingHandoff)
            case .cancelled:
                transition(to: .cancelled)
                activeOperationID = nil
            case .failed(let failure):
                transition(to: .failed(failure))
                activeOperationID = nil
            case .unsupported(let failure):
                transition(to: .unsupported(failure))
                activeOperationID = nil
            }
        } catch {
            guard activeOperationID == operationID else { return }
            transition(to: .failed(.packageRejected(String(describing: error))))
            activeOperationID = nil
        }
    }

    /// Called only after a system document/share activity reports its result.
    /// `completed` means the file was handed to the selected app, not that the
    /// receiving app installed it.
    public func completeExternalHandoff(completed: Bool, destination: String?, error: Error?) {
        guard case .awaitingHandoff = state,
              activeOperationID != nil,
              let backend = pendingBackend,
              let package = pendingHandoffPackage,
              let record = pendingPackageRecord else { return }

        defer {
            activeOperationID = nil
            pendingHandoffPackage = nil
            pendingHandoffBackendIdentifier = nil
            pendingBackend = nil
            pendingPackageRecord = nil
        }

        if let error {
            transition(to: .failed(InstallationFailure(
                code: .installationFailed,
                title: "Handoff Failed",
                userMessage: "The package could not be handed off. Try again or choose another destination.",
                technicalDetails: String(describing: error)
            )))
            return
        }
        guard completed else {
            transition(to: .cancelled)
            return
        }

        let receipt = InstallationHandoffReceipt(
            bundleIdentifier: package.bundleIdentifier,
            version: package.version,
            method: backend.identifier == TrollStoreBackend().identifier
                ? (TrollStoreImportTarget.displayName(for: destination) ?? "System Open In")
                : backend.displayName,
            destination: destination,
            handedOffAt: Date()
        )
        historyStore.record(package, storedPackage: record, receipt: receipt)
        transition(to: .handedOff(receipt))
    }

    public func cancel() {
        guard state.isActive else { return }
        activeInstallationTask?.cancel()
        activeInstallationTask = nil
        if let backend = activeInstallationBackend {
            Task { await backend.cancelInstall() }
        }
        activeInstallationBackend = nil
        activeOperationID = nil
        pendingHandoffPackage = nil
        pendingHandoffBackendIdentifier = nil
        pendingBackend = nil
        pendingPackageRecord = nil
        transition(to: .cancelled)
    }

    public func reset() {
        guard !state.isActive else { return }
        pendingHandoffPackage = nil
        pendingHandoffBackendIdentifier = nil
        pendingBackend = nil
        pendingPackageRecord = nil
        transition(to: .ready)
    }

    /// Update flow deliberately selects the paired Companion only. Other
    /// installation methods cannot confirm replacement of an installed app.
    public func installForUpdate(package: VerifiedPackage) async -> InstallationDirective {
        await installForUpdate(package: package, onState: { _ in })
    }

    public func installForUpdate(package: VerifiedPackage, onState: @escaping InstallationStateObserver) async -> InstallationDirective {
        await refreshBackendOptions()
        guard let option = backendOptions.first(where: { $0.identifier == "windows-companion" }),
              option.availability == .available,
              option.capabilities.contains(.confirmedInstall),
              option.capabilities.contains(.inventory) else {
            return .unsupported(.unavailable("Windows Companion must be connected, paired, and ready to sign before updating.")))
        }
        var backendReportedProgress = false
        stateObserver = { state in
            switch state {
            case .connectingToCompanion, .transferringPackage, .verifyingOnCompanion, .signing, .provisioning:
                backendReportedProgress = true
                onState(state)
            case .installing where !backendReportedProgress:
                // beginInstall's initial state means the coordinator is about
                // to contact the Companion; the backend has not started the
                // actual device installation yet.
                onState(.connectingToCompanion)
            default:
                onState(state)
            }
        }
        defer { stateObserver = nil }
        if !state.isActive { reset() }
        await beginInstall(package: package, backendIdentifier: option.identifier)
        switch state {
        case .installed(let app): return .installed(app)
        case .cancelled: return .cancelled
        case .failed(let failure): return .failed(failure)
        case .unsupported(let failure): return .unsupported(failure)
        case .handedOff, .awaitingHandoff:
            return .failed(InstallationFailure(
                code: .installationUnconfirmed,
                title: "Update Couldn’t Be Confirmed",
                userMessage: "The selected method handed off a file but did not confirm an update.",
                technicalDetails: "Update flow must complete through Windows Companion inventory."
            ))
        default:
            return .failed(InstallationFailure(
                code: .installationUnconfirmed,
                title: "Update Couldn’t Be Confirmed",
                userMessage: "Installation did not return a confirmed result.",
                technicalDetails: "Unexpected coordinator state: \(state)"
            ))
        }
    }

    public func refreshInstalledApp(_ app: InstalledAppRecord) async -> InstallationDirective {
        guard app.source == .companionConfirmed,
              let backend = backends.first(where: { $0.identifier == "windows-companion" }),
              let refreshBackend = backend as? any InstalledAppRefreshing else {
            return .unsupported(.configurationRequired("Refresh requires a Companion-confirmed app and the Windows Companion refresh service.")))
        }
        await backend.refreshAvailability()
        guard backend.availability == .available else {
            return .unsupported(.unavailable("Reconnect Windows Companion and configure a current signing profile to refresh this app.")))
        }
        return await refreshBackend.refreshInstalledApp(app)
    }

    public func uninstall(bundleIdentifier: String, using backendIdentifier: String) async -> UninstallationResult {
        guard bundleIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
              let backend = backends.first(where: { $0.identifier == backendIdentifier }) else {
            return .unsupported(reason: "No uninstall-capable installation backend is available.")
        }
        guard backend.capabilities.contains(.uninstall) else {
            return .unsupported(reason: "This installation method cannot uninstall applications.")
        }
        return await backend.uninstall(bundleIdentifier: bundleIdentifier)
    }

    public func queryInstalledState(bundleIdentifier: String, using backendIdentifier: String) async -> InstalledState {
        guard bundleIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
              let backend = backends.first(where: { $0.identifier == backendIdentifier }) else {
            return .unsupported(reason: "No backend provides a supported installed-app query.")
        }
        guard backend.availability == .available, backend.capabilities.contains(.installedState) else {
            return .unsupported(reason: "This installation method cannot query installed-app state.")
        }
        return await backend.queryInstalledState(bundleIdentifier: bundleIdentifier)
    }

    private func transition(to nextState: InstallationState) {
        state = nextState
        stateHistory.append(nextState)
        stateObserver?(nextState)
    }

    private func report(_ progress: InstallationProgress, operationID: UUID) {
        guard activeOperationID == operationID else { return }
        switch progress {
        case .connectingToCompanion: transition(to: .connectingToCompanion)
        case .transferringPackage: transition(to: .transferringPackage)
        case .verifyingOnCompanion: transition(to: .verifyingOnCompanion)
        case .signing: transition(to: .signing)
        case .provisioning: transition(to: .provisioning)
        case .installing: transition(to: .installing)
        }
    }
}
