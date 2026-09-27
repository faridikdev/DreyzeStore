import Combine
import Foundation

@MainActor
public final class InstallationCoordinator: ObservableObject {
    public static let shared = InstallationCoordinator(storage: .shared)

    @Published public private(set) var state: InstallationState = .ready
    public private(set) var stateHistory: [InstallationState] = [.ready]
    @Published public private(set) var backendOptions: [InstallationBackendOption] = []
    @Published public private(set) var pendingHandoffPackage: VerifiedPackage?

    private let storage: PackageStorage
    private let validator: PackageValidator
    private let backends: [any InstallationBackend]
    private let historyStore: InstallationHistoryStore
    private var activeOperationID: UUID?
    private var pendingBackend: (any InstallationBackend)?
    private var pendingPackageRecord: StoredVerifiedPackage?

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

            let directive = await backend.install(package: verified)
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

    /// Called only by the system activity controller after a user-selected
    /// activity finishes. `completed` means the activity ran, not that an app
    /// was installed.
    public func completeExternalHandoff(completed: Bool, destination: String?, error: Error?) {
        guard case .awaitingHandoff = state,
              activeOperationID != nil,
              let backend = pendingBackend,
              let package = pendingHandoffPackage,
              let record = pendingPackageRecord else { return }

        defer {
            activeOperationID = nil
            pendingHandoffPackage = nil
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
            method: backend.displayName,
            destination: destination,
            handedOffAt: Date()
        )
        historyStore.record(package, storedPackage: record, receipt: receipt)
        transition(to: .handedOff(receipt))
    }

    public func cancel() {
        guard state.isActive else { return }
        activeOperationID = nil
        pendingHandoffPackage = nil
        pendingBackend = nil
        pendingPackageRecord = nil
        transition(to: .cancelled)
    }

    public func reset() {
        guard !state.isActive else { return }
        pendingHandoffPackage = nil
        pendingBackend = nil
        pendingPackageRecord = nil
        transition(to: .ready)
    }

    public func uninstall(bundleIdentifier: String, using backendIdentifier: String) async -> UninstallationResult {
        guard bundleIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
              let backend = backends.first(where: { $0.identifier == backendIdentifier }) else {
            return .unsupported(reason: "No uninstall-capable installation backend is available.")
        }
        guard backend.availability == .available, backend.capabilities.contains(.uninstall) else {
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
    }
}
