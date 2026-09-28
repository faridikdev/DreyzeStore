import SwiftUI

struct UpdatesView: View {
    @StateObject private var model: UpdatesViewModel
    @State private var selectedUpdate: UpdateAvailable?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(repository: (any StoreRepository)?) {
        _model = StateObject(wrappedValue: UpdatesViewModel(repository: repository))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if model.state == .offlineCached || model.inventoryState.isCached { OfflineNotice() }
                if let status = model.inventoryStatusMessage, case .unavailable = model.inventoryState {
                    CompanionStatusCard(message: status, ready: false)
                } else if !model.inventory.isEmpty {
                    CompanionStatusCard(message: companionDescription, ready: model.isInventoryLive)
                }

                if isInitialLoading {
                    VStack(spacing: 12) { ForEach(0..<3, id: \.self) { _ in StoreSkeletonCard() } }
                } else {
                    if !model.updateCheckIsFresh && model.updates.isEmpty && model.recentlyUpdated.isEmpty {
                        StoreLoadError(title: "Couldn’t Check for Updates", message: failedUpdateCheckMessage) { Task { await model.load(refresh: true) } }
                    }
                    if !model.expiringRecords.isEmpty { expiringSection }
                    if !model.updates.isEmpty { updatesSection }
                    if !model.recentlyUpdated.isEmpty { recentlyUpdatedSection }
                    if !model.upToDateApps.isEmpty { upToDateSection }
                    if !model.updateHistory.isEmpty { historySection }

                    if model.updates.isEmpty && model.expiringRecords.isEmpty && model.recentlyUpdated.isEmpty && model.upToDateApps.isEmpty
                        && (model.updateCheckIsFresh || model.state == .offlineCached) {
                        StoreEmptyState(
                            symbol: model.updateCheckIsFresh ? "checkmark.circle" : "wifi.slash",
                            title: model.updateCheckIsFresh ? "No Updates to Show" : "Update Check Needed",
                            message: model.updateCheckIsFresh
                                ? (model.inventory.isEmpty ? "Windows Companion reports no installed apps for this iPhone." : "No newer published releases were found for the apps listed by this Companion.")
                                : "The saved catalog state is not a current update check. Connect to the internet and refresh."
                        ).padding(.top, 12)
                    }
                }

                if let summary = model.lastOperationSummary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(StorePalette.accent)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                if let message = model.operationMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 36)
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("Update Channel", selection: Binding(get: { model.channel }, set: model.setChannel)) {
                        Text("Stable").tag(AppUpdateChannel.stable)
                        Text("Beta").tag(AppUpdateChannel.beta)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").accessibilityLabel("Update channel")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() }
        }
        .refreshable { await model.load(refresh: true) }
        .onAppear { model.refreshPreferences() }
        .task { await model.load() }
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9), value: model.updates.count)
        .sheet(item: $selectedUpdate) { update in UpdateDetailsSheet(update: update, installed: model.inventory.first { $0.canonicalBundleIdentifier == update.app.bundleIdentifier }) }
    }

    private var isInitialLoading: Bool {
        (model.state == .idle || model.state == .loading) && model.inventory.isEmpty && model.recentlyUpdatedApps.isEmpty
    }

    private var companionDescription: String {
        switch model.inventoryState {
        case .live(let snapshot):
            let inventory = "Live iPhone inventory · checked \(snapshot.lastChecked.formatted(date: .omitted, time: .shortened))"
            switch model.companionAvailability {
            case .available: return "\(inventory) · Signing ready"
            case .unavailable(let reason), .unsupported(let reason): return "\(inventory) · \(reason)"
            case .requiresConfiguration(let reason): return "\(inventory) · Setup required: \(reason)"
            }
        case .cached(let snapshot): return "Last checked \(snapshot.lastChecked.formatted(date: .abbreviated, time: .shortened)) · saved inventory"
        default: return "Companion inventory unavailable"
        }
    }

    private var failedUpdateCheckMessage: String {
        if case .error(let message) = model.state { return message }
        return "Connect to the internet or pull to refresh. A saved inventory does not prove that the catalog has been checked recently."
    }

    private var expiringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                StoreSectionHeading(title: "Signing Refresh Required", eyebrow: "Expiring Soon")
                Spacer()
                if model.expiringRecords.count > 1 {
                    Button("Refresh All") { Task { await model.refreshAll() } }
                        .font(.subheadline.weight(.semibold)).disabled(!model.canRefreshSigning || model.isBatchRunning)
                }
            }
            ForEach(model.expiringRecords) { record in
                ExpiringAppCard(record: record, app: model.catalogApps.first { $0.bundleIdentifier == record.canonicalBundleIdentifier }, active: model.activeBundleIdentifier == record.canonicalBundleIdentifier, enabled: model.canRefreshSigning) {
                    Task { await model.refresh(record) }
                }
            }
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                StoreSectionHeading(title: "Updates Available", eyebrow: "Ready when you are")
                Spacer()
                if model.updates.count > 1 {
                    Button("Update All") { Task { await model.updateAll() } }
                        .font(.subheadline.weight(.semibold)).disabled(!model.canPerformStoreOperations || model.isBatchRunning)
                }
            }
            ForEach(model.updates) { update in
                UpdateCard(
                    update: update,
                    installed: model.inventory.first { $0.canonicalBundleIdentifier == update.app.bundleIdentifier },
                    state: model.updateState(for: update.app.bundleIdentifier),
                    progress: model.downloadProgress[update.app.bundleIdentifier],
                    active: model.activeBundleIdentifier == update.app.bundleIdentifier,
                    enabled: model.canPerformStoreOperations && !model.isBatchRunning
                ) {
                    Task { await model.update(update) }
                } details: {
                    selectedUpdate = update
                } cancel: {
                    model.cancelActiveOperation()
                }
            }
        }
    }

    private var recentlyUpdatedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreSectionHeading(title: "Recently Updated", eyebrow: "On this device")
            ForEach(model.recentlyUpdated.prefix(5)) { entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.result == .updated ? "arrow.down.circle.fill" : "arrow.clockwise.circle.fill")
                        .font(.title2).foregroundStyle(StorePalette.accent).frame(width: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.appName).font(.headline).lineLimit(1)
                        Text(entry.result == .updated ? "\(entry.oldVersion) → \(entry.newVersion)" : "Signing refreshed · Version \(entry.newVersion)")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(14).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreSectionHeading(title: "Update History", eyebrow: "This device")
            ForEach(model.updateHistory.prefix(8)) { entry in
                HStack(spacing: 12) {
                    Image(systemName: historySymbol(for: entry.result))
                        .font(.title3).foregroundStyle(historyColor(for: entry.result)).frame(width: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.appName).font(.headline).lineLimit(1)
                        Text("\(entry.oldVersion) → \(entry.newVersion)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if entry.result == .failed, let message = entry.message {
                            Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(historyTitle(for: entry.result)).font(.caption.weight(.semibold))
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(13).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func historyTitle(for result: UpdateHistoryResult) -> String {
        switch result {
        case .updated: "Updated"
        case .refreshed: "Refreshed"
        case .failed: "Failed"
        }
    }

    private func historySymbol(for result: UpdateHistoryResult) -> String {
        switch result {
        case .updated: "arrow.down.circle.fill"
        case .refreshed: "arrow.clockwise.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func historyColor(for result: UpdateHistoryResult) -> Color {
        result == .failed ? .orange : StorePalette.accent
    }

    private var upToDateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreSectionHeading(title: "Up to Date", eyebrow: "Published releases checked")
            ForEach(model.upToDateApps) { item in
                HStack(spacing: 12) {
                    RemoteStoreImage(url: item.app.iconURL, cornerRadius: 15).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.app.name).font(.headline).lineLimit(1)
                        Text("Version \(item.record.version ?? "—") · Build \(item.record.build ?? "—")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StorePalette.accent)
                        .accessibilityLabel("Up to date")
                }
                .padding(12).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct CompanionStatusCard: View {
    let message: String
    let ready: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "iphone.gen3.radiowaves.left.and.right" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.title3).foregroundStyle(ready ? StorePalette.accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(ready ? "Companion Connected" : "Companion Needed").font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct UpdateCard: View {
    let update: UpdateAvailable
    let installed: InstalledAppRecord?
    let state: UpdateState
    let progress: DownloadProgress?
    let active: Bool
    let enabled: Bool
    let updateAction: () -> Void
    let details: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                RemoteStoreImage(url: update.app.iconURL, cornerRadius: 17).frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(update.app.name).font(.headline).lineLimit(1)
                    Text(update.app.developer.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(update.installedVersion) → \(update.latestVersion.version)")
                        .font(.caption.weight(.semibold)).foregroundStyle(StorePalette.accent)
                }
                Spacer(minLength: 0)
                Button("Details", action: details).font(.caption.weight(.semibold)).buttonStyle(.plain)
                    .accessibilityLabel("Details for \(update.app.name) update")
            }
            Text(update.latestVersion.releaseNotes.isEmpty ? (update.app.shortDescription ?? "A new version is available.") : update.latestVersion.releaseNotes)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Label(ByteCountFormatter.string(fromByteCount: update.latestVersion.size, countStyle: .file), systemImage: "arrow.down.to.line")
                Text("·")
                Text("Build \(installed?.build ?? update.installedBuild ?? "—") → \(update.latestVersion.build)")
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.tertiary)

            if !isCompatible {
                Label("Requires iOS \(update.latestVersion.minimumOSVersion) or later", systemImage: "iphone.slash")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
            } else if let expiration = installed?.provisionExpiration, expiration <= Date() {
                Label("Signing expired · Refresh setup on Windows", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
            } else if let progress, active {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fractionCompleted).tint(StorePalette.accent)
                    Text("\(Int(progress.fractionCompleted * 100))%").font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
                    Button("Cancel", action: cancel).font(.caption.weight(.semibold))
                }
            } else if active {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(statusText).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: cancel).font(.caption.weight(.semibold))
                }
            } else if case .failed(let message) = state {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if state == .signingExpired {
                Text("Signing profile expired. Replace it in Windows Companion before refreshing this app.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if state == .companionUnavailable {
                Text("Windows Companion is unavailable. Reconnect the paired PC and refresh inventory.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Button(action: updateAction) {
                HStack(spacing: 8) {
                    if active { ProgressView().tint(.white).controlSize(.small) }
                    Text(buttonTitle).font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent).tint(StorePalette.accent)
            .disabled(!enabled || active || !isCompatible)
            .accessibilityHint("Downloads and verifies the new release, then installs through Windows Companion.")
        }
        .padding(15).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private var isCompatible: Bool {
        guard let required = SemanticVersion(update.latestVersion.minimumOSVersion) else { return false }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard let current = SemanticVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)") else { return false }
        return required <= current
    }
    private var buttonTitle: String {
        if active { return statusText.uppercased() }
        if case .failed = state { return "RETRY" }
        if state == .updated { return "UPDATED" }
        return "UPDATE"
    }
    private var statusText: String {
        switch state {
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .readyToInstall: "Package Ready"
        case .connectingToCompanion: "Connecting to Companion"
        case .signing: "Signing"
        case .installing: "Installing"
        case .confirming: "Confirming on iPhone"
        default: "Updating"
        }
    }
}

private struct ExpiringAppCard: View {
    let record: InstalledAppRecord
    let app: StoreApp?
    let active: Bool
    let enabled: Bool
    let refresh: () -> Void

    private var expiresInText: String {
        guard let expiration = record.provisionExpiration else { return "Expiration unavailable" }
        if expiration <= Date() { return "Expired \(expiration.formatted(date: .abbreviated, time: .omitted))" }
        let days = max(0, Int(ceil(expiration.timeIntervalSinceNow / 86_400)))
        return days == 1 ? "Expires in 1 day" : "Expires in \(days) days"
    }

    var body: some View {
        HStack(spacing: 12) {
            RemoteStoreImage(url: app?.iconURL, cornerRadius: 15).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(app?.name ?? record.canonicalBundleIdentifier).font(.headline).lineLimit(1)
                Text(expiresInText).font(.caption.weight(.medium)).foregroundStyle(.orange)
                if let team = record.teamIdentifier { Text("Team \(team)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Button(action: refresh) {
                if active { ProgressView().controlSize(.small) }
                else { Text("Refresh").font(.caption.weight(.bold)) }
            }
            .buttonStyle(.bordered).tint(StorePalette.accent).disabled(active || !enabled)
            .accessibilityLabel("Refresh signing for \(app?.name ?? record.canonicalBundleIdentifier)")
        }
        .padding(13).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct UpdateDetailsSheet: View {
    let update: UpdateAvailable
    let installed: InstalledAppRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        RemoteStoreImage(url: update.app.iconURL, cornerRadius: 18).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(update.app.name).font(.headline)
                            Text(update.app.developer.name).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                Section("Version") {
                    LabeledContent("Version", value: "\(update.installedVersion) → \(update.latestVersion.version)")
                    LabeledContent("Build", value: "\(installed?.build ?? update.installedBuild ?? "—") → \(update.latestVersion.build)")
                    LabeledContent("Download Size", value: ByteCountFormatter.string(fromByteCount: update.latestVersion.size, countStyle: .file))
                    LabeledContent("Minimum iOS", value: update.latestVersion.minimumOSVersion)
                    LabeledContent("Published", value: update.latestVersion.versionDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                Section("What’s New") {
                    Text(update.latestVersion.releaseNotes.isEmpty ? "No release notes were provided." : update.latestVersion.releaseNotes)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let expiration = installed?.provisionExpiration {
                    Section("Signing") {
                        LabeledContent("Provisioning Expires", value: expiration.formatted(date: .abbreviated, time: .shortened))
                        Text("Installed via DreyzeStore Companion").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Package") {
                    LabeledContent("Bundle ID", value: update.app.bundleIdentifier)
                    LabeledContent("Channel", value: update.channel.capitalized)
                    LabeledContent("SHA-256", value: update.latestVersion.sha256).textSelection(.enabled)
                }
            }
            .navigationTitle("Update Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
