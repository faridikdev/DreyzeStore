import Combine
import Foundation

@MainActor
protocol UpdateInventorySynchronizing: AnyObject {
    var state: InstalledInventoryState { get }
    var currentSnapshot: InstalledInventorySnapshot? { get }
    var isLive: Bool { get }
    func synchronize() async -> InstalledInventorySnapshot?
}

extension InstalledInventoryService: UpdateInventorySynchronizing { }

@MainActor
protocol UpdatePackageManaging: AnyObject {
    func state(for app: StoreApp) -> PackageDownloadState
    func start(app: StoreApp)
    func retry(app: StoreApp)
    func cancel(app: StoreApp)
    func refreshPackages()
    func prunePreviousPackages(bundleIdentifier: String, keeping package: VerifiedPackage) throws
}

extension DownloadManager: UpdatePackageManaging { }

@MainActor
protocol UpdateInstallationManaging: AnyObject {
    func installForUpdate(package: VerifiedPackage, onState: @escaping InstallationStateObserver) async -> InstallationDirective
    func refreshInstalledApp(_ app: InstalledAppRecord) async -> InstallationDirective
    func uninstall(bundleIdentifier: String, using backendIdentifier: String) async -> UninstallationResult
    func cancel()
    func checkCompanionAvailability() async -> BackendAvailability
}

extension InstallationCoordinator: UpdateInstallationManaging {
    func checkCompanionAvailability() async -> BackendAvailability {
        await refreshBackendOptions()
        return backendOptions.first(where: { $0.identifier == "windows-companion" })?.availability
            ?? .unavailable(reason: "Windows Companion is not available in this build.")
    }
}

private struct CachedUpdateSnapshot: Codable {
    let deviceIdentifier: String
    let channel: AppUpdateChannel
    let installed: [InstalledVersion]
    let updates: [UpdateAvailable]
    let catalogApps: [StoreApp]
    let checkedAt: Date
}

@MainActor
final class UpdatesViewModel: ObservableObject {
    @Published private(set) var state: StoreScreenState = .idle
    @Published private(set) var inventoryState: InstalledInventoryState = .idle
    @Published private(set) var inventory: [InstalledAppRecord] = []
    @Published private(set) var updates: [UpdateAvailable] = []
    @Published private(set) var catalogApps: [StoreApp] = []
    @Published private(set) var recentlyUpdatedApps: [StoreApp] = []
    @Published private(set) var updateStates: [String: UpdateState] = [:]
    @Published private(set) var downloadProgress: [String: DownloadProgress] = [:]
    @Published private(set) var checkedAt: Date?
    @Published private(set) var updateCheckIsFresh = false
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var companionAvailability: BackendAvailability = .requiresConfiguration(reason: "Pair a Windows Companion to manage installed apps.")
    @Published private(set) var activeBundleIdentifier: String?
    @Published private(set) var isBatchRunning = false
    @Published private(set) var operationMessage: String?
    @Published private(set) var lastOperationSummary: String?
    @Published var channel: AppUpdateChannel {
        didSet {
            defaults.set(channel.rawValue, forKey: channelKey)
            if oldValue != channel { Task { await load(refresh: true) } }
        }
    }
    @Published var signingWarningDays: Int {
        didSet { defaults.set(signingWarningDays, forKey: warningDaysKey) }
    }

    let repository: (any StoreRepository)?
    private let inventoryService: any UpdateInventorySynchronizing
    private let packages: any UpdatePackageManaging
    private let installation: any UpdateInstallationManaging
    private let history: UpdateHistoryStore
    private let defaults: UserDefaults
    private let channelKey = "dreyze.updates.channel.v1"
    private let warningDaysKey = "dreyze.updates.signing-warning-days.v1"
    private let keepPreviousKey = "dreyze.updates.keep-previous-package.v1"
    private let notificationsKey = "dreyze.notifications.enabled.v1"
    private let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    private var isLoading = false

    init(
        repository: (any StoreRepository)?,
        inventory: any UpdateInventorySynchronizing = InstalledInventoryService.shared,
        packages: any UpdatePackageManaging = DownloadManager.shared,
        installation: any UpdateInstallationManaging = InstallationCoordinator.shared,
        history: UpdateHistoryStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.inventoryService = inventory
        self.packages = packages
        self.installation = installation
        self.history = history
        self.defaults = defaults
        self.channel = AppUpdateChannel(rawValue: defaults.string(forKey: channelKey) ?? "stable") ?? .stable
        self.signingWarningDays = min(30, max(1, defaults.object(forKey: warningDaysKey) as? Int ?? 7))
        self.notificationsEnabled = defaults.bool(forKey: notificationsKey)
    }

    var isInventoryLive: Bool { inventoryService.isLive }
    var canPerformStoreOperations: Bool { isInventoryLive && updateCheckIsFresh && companionAvailability == .available }
    var canRefreshSigning: Bool { isInventoryLive && companionAvailability == .available }
    var updateAllEligible: [UpdateAvailable] {
        updates.filter { update in
            updateStates[update.app.bundleIdentifier] != .incompatible(Self.compatibilityMessage(for: update.latestVersion.minimumOSVersion))
        }
    }
    var upToDateApps: [UpToDateApp] {
        let updateIDs = Set(updates.map { $0.app.bundleIdentifier.lowercased() })
        return inventory.compactMap { record in
            guard record.source == .companionConfirmed,
                  let app = catalogApps.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(record.canonicalBundleIdentifier) == .orderedSame }),
                  !updateIDs.contains(record.canonicalBundleIdentifier.lowercased()) else { return nil }
            return UpToDateApp(record: record, app: app)
        }
    }
    var expiringRecords: [InstalledAppRecord] {
        let cutoff = Date().addingTimeInterval(TimeInterval(signingWarningDays * 24 * 60 * 60))
        return inventory.filter {
            $0.source == .companionConfirmed
                && $0.provisionExpiration.map { $0 <= cutoff } == true
        }.sorted { ($0.provisionExpiration ?? .distantFuture) < ($1.provisionExpiration ?? .distantFuture) }
    }
    var recentlyUpdated: [UpdateHistoryRecord] { history.recentlyUpdated }
    var updateHistory: [UpdateHistoryRecord] { history.records }
    var keepPreviousVersion: Bool {
        get { defaults.object(forKey: keepPreviousKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: keepPreviousKey) }
    }
    var inventoryStatusMessage: String? {
        switch inventoryState {
        case .cached(let snapshot): "Last checked \(snapshot.lastChecked.formatted(date: .abbreviated, time: .shortened)). Showing the saved Companion inventory."
        case .unavailable(let message): message
        default: nil
        }
    }

    func load(refresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        updateCheckIsFresh = false
        defer { isLoading = false }
        let hasContent = !updates.isEmpty || !inventory.isEmpty || !recentlyUpdatedApps.isEmpty
        state = hasContent ? (refresh ? .refreshing : state) : .loading
        inventoryState = .loading
        let snapshot = await inventoryService.synchronize()
        inventoryState = inventoryService.state
        inventory = snapshot?.records ?? []
        companionAvailability = await installation.checkCompanionAvailability()

        guard let repository else {
            state = hasContent ? .offlineCached : .error(StoreError.configurationUnavailable.userMessage)
            return
        }

        async let recentResult = try? await repository.apps(page: 1, limit: 12, category: nil, sort: .updated)
        if let snapshot {
            let records = normalizedConfirmedInventory(snapshot.records)
            let installed = records.map {
                InstalledVersion(bundleIdentifier: $0.canonicalBundleIdentifier, installedVersion: $0.version!, installedBuild: $0.build, channel: channel.rawValue)
            }
            if inventoryService.isLive {
                do {
                    var fetchedUpdates: [UpdateAvailable] = []
                    var fetchedApps: [StoreApp] = []
                    for chunk in installed.chunked(into: 25) {
                        try Task.checkCancellation()
                        fetchedUpdates.append(contentsOf: try await repository.updates(for: chunk))
                        fetchedApps.append(contentsOf: try await repository.lookupApps(bundleIdentifiers: chunk.map(\.bundleIdentifier), channel: channel))
                    }
                    updates = validatedUpdates(fetchedUpdates, against: records)
                    catalogApps = uniqueApps(fetchedApps + updates.map(\.app))
                    checkedAt = Date()
                    state = .loaded
                    updateCheckIsFresh = true
                    saveCache(deviceIdentifier: snapshot.deviceIdentifier, installed: installed)
                } catch is CancellationError {
                    updateCheckIsFresh = false
                    state = hasContent ? .offlineCached : .idle
                } catch {
                    let restored = useCache(deviceIdentifier: snapshot.deviceIdentifier, installed: installed)
                    updateCheckIsFresh = false
                    if restored {
                        state = .offlineCached
                    } else {
                        updates = []
                        catalogApps = []
                        checkedAt = nil
                        state = .error(StoreFailure.message(for: error))
                    }
                }
            } else {
                let restored = useCache(deviceIdentifier: snapshot.deviceIdentifier, installed: installed)
                updateCheckIsFresh = false
                if !restored { updates = []; catalogApps = []; checkedAt = nil }
                state = restored || !inventory.isEmpty
                    ? .offlineCached
                    : .error(StoreFailure.message(for: StoreError.networkUnavailable))
            }
        } else {
            updateCheckIsFresh = false
            updates = []
            catalogApps = []
            checkedAt = nil
            state = .error(inventoryStatusMessage ?? "Connect Windows Companion to check installed apps and updates.")
        }

        if let recent = await recentResult {
            recentlyUpdatedApps = recent.value.data
            if recent.source == .cache && state == .loaded { state = .offlineCached }
        }
        updateStates = Dictionary(uniqueKeysWithValues: updates.map { ($0.app.bundleIdentifier, isCompatible($0.latestVersion.minimumOSVersion) ? .updateAvailable : .incompatible(Self.compatibilityMessage(for: $0.latestVersion.minimumOSVersion))) })
        if inventoryService.isLive && updateCheckIsFresh {
            await synchronizeNotifications()
        }
    }

    func setChannel(_ value: AppUpdateChannel) { channel = value }

    func refreshPreferences() {
        let storedChannel = AppUpdateChannel(rawValue: defaults.string(forKey: channelKey) ?? "stable") ?? .stable
        if storedChannel != channel { channel = storedChannel }
        signingWarningDays = min(30, max(1, defaults.object(forKey: warningDaysKey) as? Int ?? 7))
        notificationsEnabled = defaults.bool(forKey: notificationsKey)
    }

    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        if enabled {
            guard await UpdateNotificationService.shared.requestPermission() else {
                notificationsEnabled = false
                defaults.set(false, forKey: notificationsKey)
                operationMessage = "Notifications are disabled for DreyzeStore in iPhone Settings."
                return false
            }
        }
        notificationsEnabled = enabled
        defaults.set(enabled, forKey: notificationsKey)
        if enabled { await synchronizeNotifications() }
        else {
            await UpdateNotificationService.shared.synchronize(updates: [], installed: [], names: [:], warningDays: signingWarningDays, enabled: false)
        }
        return true
    }

    func update(_ update: UpdateAvailable) async {
        guard !active || (isBatchRunning && activeBundleIdentifier == nil) else { return }
        guard canPerformStoreOperations else {
            if !isInventoryLive {
                operationMessage = "Connect the paired Windows Companion and refresh inventory before updating."
            } else if !updateCheckIsFresh {
                operationMessage = "Connect to the internet and refresh the published update check before updating."
            } else {
                operationMessage = Self.availabilityMessage(companionAvailability)
                updateStates[update.app.bundleIdentifier] = Self.availabilityState(companionAvailability)
            }
            return
        }
        guard let record = confirmedRecord(for: update.app.bundleIdentifier) else {
            let message = "This app is no longer present in the live Companion inventory."
            updateStates[update.app.bundleIdentifier] = .failed(message)
            recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: update.installedVersion, newVersion: update.latestVersion.version, message: message)
            return
        }
        guard VersionComparator.isNewerRelease(
            candidateVersion: update.latestVersion.version,
            candidateBuild: update.latestVersion.build,
            installedVersion: record.version ?? "",
            installedBuild: record.build
        ) else {
            updateStates[update.app.bundleIdentifier] = .upToDate
            operationMessage = "The published release is not newer than the version currently reported by the iPhone."
            return
        }
        guard isCompatible(update.latestVersion.minimumOSVersion) else {
            updateStates[update.app.bundleIdentifier] = .incompatible(Self.compatibilityMessage(for: update.latestVersion.minimumOSVersion))
            return
        }

        activeBundleIdentifier = update.app.bundleIdentifier
        operationMessage = nil
        defer { activeBundleIdentifier = nil }
        do {
            let availability = await installation.checkCompanionAvailability()
            companionAvailability = availability
            guard availability == .available else {
                let reason = Self.availabilityMessage(availability)
                updateStates[update.app.bundleIdentifier] = Self.availabilityState(availability)
                operationMessage = reason
                recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: reason)
                return
            }
            let package = try await verifiedPackage(for: update.app)
            updateStates[update.app.bundleIdentifier] = .readyToInstall
            updateStates[update.app.bundleIdentifier] = .connectingToCompanion
            let directive = await installation.installForUpdate(package: package) { [weak self] state in
                self?.updateStates[update.app.bundleIdentifier] = Self.updateState(for: state)
            }
            switch directive {
            case .installed(let installed):
                guard installed.version == package.version, installed.build == package.build else {
                    throw UpdateFlowFailure.confirmation("The Companion installation receipt did not match the downloaded version and build.")
                }
                updateStates[update.app.bundleIdentifier] = .confirming
                let confirmed = await confirmInstalled(package: package, canonicalBundleIdentifier: update.app.bundleIdentifier, signedBundleIdentifier: installed.bundleIdentifier)
                guard confirmed else {
                    throw UpdateFlowFailure.confirmation("Installation could not be confirmed.")
                }
                history.record(
                    appName: update.app.name,
                    bundleIdentifier: update.app.bundleIdentifier,
                    oldVersion: record.version ?? update.installedVersion,
                    newVersion: package.version,
                    result: .updated
                )
                updateStates[update.app.bundleIdentifier] = .updated
                updates.removeAll { $0.app.bundleIdentifier == update.app.bundleIdentifier }
                if !keepPreviousVersion {
                    try? packages.prunePreviousPackages(bundleIdentifier: package.bundleIdentifier, keeping: package)
                }
                lastOperationSummary = "\(update.app.name) updated to \(package.version)."
                await load(refresh: true)
            case .cancelled:
                let message = "Update cancelled."
                updateStates[update.app.bundleIdentifier] = .failed(message)
                recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: message)
            case .failed(let failure), .unsupported(let failure):
                let message = failure.userMessage
                updateStates[update.app.bundleIdentifier] = .failed(message)
                operationMessage = message
                recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: message)
            case .handoffRequested:
                let message = "The selected method only handed off the package and cannot confirm an update."
                updateStates[update.app.bundleIdentifier] = .failed(message)
                recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: message)
            }
        } catch is CancellationError {
            let message = "Update cancelled."
            updateStates[update.app.bundleIdentifier] = .failed(message)
            recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: message)
        } catch let error as UpdateFlowFailure {
            updateStates[update.app.bundleIdentifier] = .failed(error.message)
            operationMessage = error.message
            recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: error.message)
        } catch let error as PackageDownloadFailure {
            updateStates[update.app.bundleIdentifier] = .failed(error.userMessage)
            operationMessage = error.userMessage
            recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: error.userMessage)
        } catch {
            let message = StoreFailure.message(for: error)
            updateStates[update.app.bundleIdentifier] = .failed(message)
            operationMessage = message
            recordFailure(appName: update.app.name, bundleIdentifier: update.app.bundleIdentifier, oldVersion: record.version ?? update.installedVersion, newVersion: update.latestVersion.version, message: message)
        }
    }

    func updateAll() async {
        guard !active else { return }
        guard canPerformStoreOperations else { operationMessage = "Connect Windows Companion and refresh inventory before using Update All."; return }
        let candidates = updateAllEligible.filter { update in
            guard confirmedRecord(for: update.app.bundleIdentifier) != nil,
                  isCompatible(update.latestVersion.minimumOSVersion) else { return false }
            if case .available = companionAvailability { return true }
            return false
        }
        guard !candidates.isEmpty else { operationMessage = "No compatible, Companion-confirmed updates are ready."; return }
        isBatchRunning = true
        var succeeded = 0
        var failed = 0
        var signingRequired = 0
        defer { activeBundleIdentifier = nil; isBatchRunning = false }
        for candidate in candidates {
            let previousHistoryID = history.records.first?.id
            await update(candidate)
            if let result = history.records.first, result.id != previousHistoryID {
                switch result.result {
                case .updated: succeeded += 1
                case .failed where Self.isSigningFailure(result.message): signingRequired += 1
                default: failed += 1
                }
            } else { failed += 1 }
        }
        activeBundleIdentifier = nil
        let results = [succeeded > 0 ? "\(succeeded) Updated" : nil, failed > 0 ? "\(failed) Failed" : nil, signingRequired > 0 ? "\(signingRequired) Signing Required" : nil].compactMap { $0 }
        lastOperationSummary = results.isEmpty ? "No updates were processed." : results.joined(separator: " · ")
    }

    func refresh(_ record: InstalledAppRecord) async {
        guard !active || (isBatchRunning && activeBundleIdentifier == nil) else { return }
        guard isInventoryLive, record.source == .companionConfirmed else {
            operationMessage = "Connect Windows Companion to refresh signing for this installed app."
            return
        }
        activeBundleIdentifier = record.canonicalBundleIdentifier
        defer { activeBundleIdentifier = nil }
        let availability = await installation.checkCompanionAvailability()
        companionAvailability = availability
        guard availability == .available else {
            let message = Self.availabilityMessage(availability)
            operationMessage = message
            updateStates[record.canonicalBundleIdentifier] = Self.availabilityState(availability)
            recordFailure(appName: catalogApps.first(where: { $0.bundleIdentifier == record.canonicalBundleIdentifier })?.name ?? record.canonicalBundleIdentifier, bundleIdentifier: record.canonicalBundleIdentifier, oldVersion: record.version ?? "—", newVersion: record.version ?? "—", message: message)
            return
        }
        let oldVersion = record.version ?? "—"
        let directive = await installation.refreshInstalledApp(record)
        switch directive {
        case .installed(let receipt):
            guard receipt.version == record.version, receipt.build == record.build else {
                operationMessage = "Installation could not be confirmed."
                updateStates[record.canonicalBundleIdentifier] = .failed(operationMessage!)
                recordFailure(appName: catalogApps.first(where: { $0.bundleIdentifier == record.canonicalBundleIdentifier })?.name ?? record.canonicalBundleIdentifier, bundleIdentifier: record.canonicalBundleIdentifier, oldVersion: oldVersion, newVersion: oldVersion, message: operationMessage!)
                return
            }
            let fresh = await inventoryService.synchronize()
            inventoryState = inventoryService.state
            guard let fresh, inventoryService.isLive,
                  let updated = fresh.records.first(where: { $0.source == .companionConfirmed && $0.installedBundleIdentifier == receipt.bundleIdentifier && $0.canonicalBundleIdentifier == record.canonicalBundleIdentifier }),
                  updated.version == record.version, updated.build == record.build,
                  let newExpiration = updated.provisionExpiration,
                  newExpiration > Date(),
                  (record.provisionExpiration == nil || newExpiration > record.provisionExpiration!) else {
                operationMessage = "Signing refresh could not be confirmed from the live iPhone inventory."
                updateStates[record.canonicalBundleIdentifier] = .failed(operationMessage!)
                recordFailure(appName: catalogApps.first(where: { $0.bundleIdentifier == record.canonicalBundleIdentifier })?.name ?? record.canonicalBundleIdentifier, bundleIdentifier: record.canonicalBundleIdentifier, oldVersion: oldVersion, newVersion: oldVersion, message: operationMessage!)
                return
            }
            history.record(appName: catalogApps.first(where: { $0.bundleIdentifier == record.canonicalBundleIdentifier })?.name ?? record.canonicalBundleIdentifier, bundleIdentifier: record.canonicalBundleIdentifier, oldVersion: oldVersion, newVersion: oldVersion, result: .refreshed)
            updateStates[record.canonicalBundleIdentifier] = .upToDate
            await load(refresh: true)
        case .cancelled:
            let message = "Refresh cancelled."
            updateStates[record.canonicalBundleIdentifier] = .failed(message)
            recordFailure(appName: catalogApps.first(where: { $0.bundleIdentifier == record.canonicalBundleIdentifier })?.name ?? record.canonicalBundleIdentifier, bundleIdentifier: record.canonicalBundleIdentifier, oldVersion: oldVersion, newVersion: oldVersion, message: message)
        case .failed(let failure), .unsupported(let failure):
            operationMessage = failure.userMessage
            updateStates[record.canonicalBundleIdentifier] = .failed(failure.userMessage)
            recordFailure(appName: catalogApps.first(where: { $0.bundleIdentifier == record.canonicalBundleIdentifier })?.name ?? record.canonicalBundleIdentifier, bundleIdentifier: record.canonicalBundleIdentifier, oldVersion: oldVersion, newVersion: oldVersion, message: failure.userMessage)
        case .handoffRequested:
            let message = "Signing refresh cannot be confirmed through a file handoff."
            operationMessage = message
            updateStates[record.canonicalBundleIdentifier] = .failed(message)
            recordFailure(appName: catalogApps.first(where: { $0.bundleIdentifier == record.canonicalBundleIdentifier })?.name ?? record.canonicalBundleIdentifier, bundleIdentifier: record.canonicalBundleIdentifier, oldVersion: oldVersion, newVersion: oldVersion, message: message)
        }
    }

    func refreshAll() async {
        guard !active else { return }
        guard isInventoryLive else {
            operationMessage = "A live Windows Companion inventory is required before Refresh All."
            return
        }
        let availability = await installation.checkCompanionAvailability()
        companionAvailability = availability
        guard availability == .available else {
            operationMessage = "Signing setup and Windows Companion must be ready before Refresh All."
            return
        }
        let candidates = expiringRecords
        guard !candidates.isEmpty else { operationMessage = "No installed apps need a signing refresh."; return }
        isBatchRunning = true
        var succeeded = 0
        var failed = 0
        for record in candidates {
            let previousHistoryID = history.records.first?.id
            await refresh(record)
            if history.records.first?.id != previousHistoryID, history.records.first?.result == .refreshed { succeeded += 1 } else { failed += 1 }
        }
        activeBundleIdentifier = nil
        isBatchRunning = false
        lastOperationSummary = [succeeded > 0 ? "\(succeeded) Refreshed" : nil, failed > 0 ? "\(failed) Failed" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    func uninstall(_ record: InstalledAppRecord) async -> Bool {
        guard !active, record.source == .companionConfirmed, inventoryService.isLive else {
            operationMessage = "A live Companion-confirmed inventory is required before uninstalling."
            return false
        }
        activeBundleIdentifier = record.canonicalBundleIdentifier
        defer { activeBundleIdentifier = nil }
        let result = await installation.uninstall(bundleIdentifier: record.installedBundleIdentifier, using: "windows-companion")
        guard case .uninstalled = result else {
            if case .failed(let failure) = result { operationMessage = failure.userMessage }
            else if case .unsupported(let reason) = result { operationMessage = reason }
            return false
        }
        guard let fresh = await inventoryService.synchronize(), inventoryService.isLive,
              !fresh.records.contains(where: { $0.source == .companionConfirmed && $0.installedBundleIdentifier == record.installedBundleIdentifier }) else {
            operationMessage = "Removal could not be confirmed from the live iPhone inventory."
            return false
        }
        inventoryState = inventoryService.state
        inventory = fresh.records
        return true
    }

    func cancelActiveOperation() {
        if let id = activeBundleIdentifier,
           let update = updates.first(where: { $0.app.bundleIdentifier == id }) {
            packages.cancel(app: update.app)
        }
        installation.cancel()
    }

    func updateState(for bundleIdentifier: String) -> UpdateState {
        updateStates[bundleIdentifier] ?? .upToDate
    }

    func downloadState(for update: UpdateAvailable) -> PackageDownloadState { packages.state(for: update.app) }

    private var active: Bool { activeBundleIdentifier != nil || isBatchRunning }

    private func verifiedPackage(for app: StoreApp) async throws -> VerifiedPackage {
        switch packages.state(for: app) {
        case .failed, .cancelled: packages.retry(app: app)
        default: packages.start(app: app)
        }
        while true {
            try Task.checkCancellation()
            switch packages.state(for: app) {
            case .idle, .preparing, .downloading:
                updateStates[app.bundleIdentifier] = .downloading
                if case .downloading(let progress) = packages.state(for: app) {
                    downloadProgress[app.bundleIdentifier] = progress
                }
            case .verifying:
                updateStates[app.bundleIdentifier] = .verifying
                downloadProgress.removeValue(forKey: app.bundleIdentifier)
            case .inspecting:
                updateStates[app.bundleIdentifier] = .verifying
            case .ready(let package):
                downloadProgress.removeValue(forKey: app.bundleIdentifier)
                return package
            case .failed(let failure): throw failure
            case .cancelled: throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func confirmInstalled(package: VerifiedPackage, canonicalBundleIdentifier: String, signedBundleIdentifier: String) async -> Bool {
        guard let snapshot = await inventoryService.synchronize(), inventoryService.isLive, snapshot.isLive else { return false }
        inventoryState = inventoryService.state
        inventory = snapshot.records
        return snapshot.records.contains {
            $0.source == .companionConfirmed
                && $0.canonicalBundleIdentifier.caseInsensitiveCompare(canonicalBundleIdentifier) == .orderedSame
                && $0.installedBundleIdentifier.caseInsensitiveCompare(signedBundleIdentifier) == .orderedSame
                && $0.version == package.version
                && $0.build == package.build
                && $0.deviceIdentifier == snapshot.deviceIdentifier
        }
    }

    private func normalizedConfirmedInventory(_ records: [InstalledAppRecord]) -> [InstalledAppRecord] {
        let eligible = records.filter {
            $0.source == .companionConfirmed
                && $0.version?.isEmpty == false
                && $0.build?.isEmpty == false
                && $0.canonicalBundleIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
        }
        let groups = Dictionary(grouping: eligible, by: { $0.canonicalBundleIdentifier.lowercased() })
        return groups.values.compactMap { $0.count == 1 ? $0[0] : nil }.sorted { $0.canonicalBundleIdentifier < $1.canonicalBundleIdentifier }
    }

    private func validatedUpdates(_ values: [UpdateAvailable], against records: [InstalledAppRecord]) -> [UpdateAvailable] {
        values.filter { update in
            guard let installed = records.first(where: { $0.canonicalBundleIdentifier.caseInsensitiveCompare(update.app.bundleIdentifier) == .orderedSame }),
                  update.channel == channel.rawValue,
                  update.installedVersion == installed.version,
                  update.installedBuild == installed.build,
                  update.latestVersion.version == update.app.currentVersion.version,
                  update.latestVersion.build == update.app.currentVersion.build,
                  update.latestVersion.sha256 == update.app.currentVersion.sha256 else { return false }
            return VersionComparator.isNewerRelease(
                candidateVersion: update.latestVersion.version,
                candidateBuild: update.latestVersion.build,
                installedVersion: installed.version ?? "",
                installedBuild: installed.build
            )
        }
    }

    private func uniqueApps(_ apps: [StoreApp]) -> [StoreApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleIdentifier.lowercased()).inserted }
    }

    private func confirmedRecord(for bundleIdentifier: String) -> InstalledAppRecord? {
        inventory.first {
            $0.source == .companionConfirmed
                && $0.canonicalBundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    private func recordFailure(appName: String, bundleIdentifier: String, oldVersion: String, newVersion: String, message: String) {
        history.record(appName: appName, bundleIdentifier: bundleIdentifier, oldVersion: oldVersion, newVersion: newVersion, result: .failed, message: message)
    }

    private static func isSigningFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        let value = message.lowercased()
        return ["signing", "provision", "certificate", "identity", "profile"].contains { value.contains($0) }
    }

    private func isCompatible(_ minimumOS: String) -> Bool {
        guard let required = SemanticVersion(minimumOS) else { return false }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard let current = SemanticVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)") else { return false }
        return required <= current
    }

    private static func compatibilityMessage(for minimumOS: String) -> String { "Requires iOS \(minimumOS) or later." }

    private static func updateState(for state: InstallationState) -> UpdateState {
        switch state {
        case .ready, .preparingInstallation, .connectingToCompanion, .transferringPackage, .awaitingHandoff:
            .connectingToCompanion
        case .verifyingOnCompanion: .verifying
        case .signing, .provisioning: .signing
        case .installing: .installing
        case .installed: .confirming
        case .handedOff: .failed("A file handoff cannot confirm an update.")
        case .failed(let failure), .unsupported(let failure): .failed(failure.userMessage)
        case .cancelled: .failed("Update cancelled.")
        }
    }

    private static func availabilityMessage(_ availability: BackendAvailability) -> String {
        switch availability {
        case .available: ""
        case .unavailable(let reason), .unsupported(let reason), .requiresConfiguration(let reason): reason
        }
    }

    private static func availabilityState(_ availability: BackendAvailability) -> UpdateState {
        switch availability {
        case .available: .upToDate
        case .unavailable, .unsupported: .companionUnavailable
        case .requiresConfiguration(let reason):
            reason.localizedCaseInsensitiveContains("expired") ? .signingExpired : .failed(reason)
        }
    }

    private func saveCache(deviceIdentifier: String, installed: [InstalledVersion]) {
        guard let data = try? JSONEncoder.updateCache.encode(CachedUpdateSnapshot(
            deviceIdentifier: deviceIdentifier,
            channel: channel,
            installed: installed,
            updates: updates,
            catalogApps: catalogApps,
            checkedAt: Date()
        )) else { return }
        defaults.set(data, forKey: cacheKey(deviceIdentifier: deviceIdentifier))
    }

    private func synchronizeNotifications() async {
        let names = Dictionary(uniqueKeysWithValues: catalogApps.map { ($0.bundleIdentifier, $0.name) })
        await UpdateNotificationService.shared.synchronize(
            updates: updates,
            installed: inventory,
            names: names,
            warningDays: signingWarningDays,
            enabled: notificationsEnabled
        )
    }

    @discardableResult
    private func useCache(deviceIdentifier: String, installed: [InstalledVersion]) -> Bool {
        guard let data = defaults.data(forKey: cacheKey(deviceIdentifier: deviceIdentifier)),
              let cached = try? JSONDecoder.updateCache.decode(CachedUpdateSnapshot.self, from: data),
              cached.deviceIdentifier == deviceIdentifier,
              cached.channel == channel,
              Date().timeIntervalSince(cached.checkedAt) <= cacheLifetime else { return false }
        let current = Dictionary(uniqueKeysWithValues: installed.map { ($0.bundleIdentifier.lowercased(), $0) })
        let cachedInstalled = Dictionary(uniqueKeysWithValues: cached.installed.map { ($0.bundleIdentifier.lowercased(), $0) })
        guard current == cachedInstalled else { return false }
        updates = cached.updates
        catalogApps = cached.catalogApps
        checkedAt = cached.checkedAt
        return true
    }

    private func cacheKey(deviceIdentifier: String) -> String {
        "dreyze.updates.snapshot.v1.\(deviceIdentifier).\(channel.rawValue)"
    }
}

private enum UpdateFlowFailure: Error {
    case confirmation(String)
    var message: String {
        switch self { case .confirmation(let value): value }
    }
}

private extension JSONEncoder {
    static var updateCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var updateCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
