import SwiftUI

private enum LibrarySection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case updates = "Updates"
    case downloaded = "Downloaded"
    case recentlyUpdated = "Recently Updated"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .installed: "square.stack.3d.up"
        case .updates: "arrow.triangle.2.circlepath"
        case .downloaded: "arrow.down.circle"
        case .recentlyUpdated: "clock.arrow.circlepath"
        }
    }
}

struct LibraryView: View {
    @StateObject private var model: UpdatesViewModel
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var handoffHistory = InstallationHistoryStore.shared
    @State private var selection: LibrarySection = .installed
    @State private var selectedForRemoval: InstalledAppRecord?
    @State private var showingRemovalConfirmation = false
    @State private var removalMessage: String?

    init(repository: (any StoreRepository)?) {
        _model = StateObject(wrappedValue: UpdatesViewModel(repository: repository))
    }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(LibrarySection.allCases) { section in
                        Button {
                            StoreHaptics.selection()
                            withAnimation(.easeInOut(duration: 0.18)) { selection = section }
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selection == section ? .white : .primary)
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .background(selection == section ? StorePalette.accent : StorePalette.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == section ? .isSelected : [])
                    }
                }.padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)

            Group {
                switch selection {
                case .installed: installedContent
                case .updates: updatesContent
                case .downloaded: downloadedContent
                case .recentlyUpdated: recentlyUpdatedContent
                }
            }
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() } }
        .task { await model.load() }
        .confirmationDialog("Uninstall this app?", isPresented: $showingRemovalConfirmation, titleVisibility: .visible) {
            Button("Uninstall App", role: .destructive) {
                guard let selectedForRemoval else { return }
                Task {
                    let removed = await model.uninstall(selectedForRemoval)
                    removalMessage = removed ? "The app was removed and the iPhone inventory confirmed it." : model.operationMessage ?? "The removal could not be confirmed."
                    self.selectedForRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) { selectedForRemoval = nil }
        } message: {
            Text("DreyzeStore will ask Windows Companion to uninstall the app. Downloaded IPA files are kept.")
        }
        .alert("Library", isPresented: Binding(get: { removalMessage != nil }, set: { if !$0 { removalMessage = nil } })) {
            Button("OK", role: .cancel) { removalMessage = nil }
        } message: { Text(removalMessage ?? "") }
    }

    private var installedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if case .cached(let snapshot) = model.inventoryState { savedInventoryNotice(snapshot.lastChecked) }
                if case .unavailable(let message) = model.inventoryState, model.inventory.isEmpty {
                    StoreLoadError(title: "Installed Apps Unavailable", message: message) { Task { await model.load(refresh: true) } }
                } else if model.inventory.filter(\.isCompanionConfirmed).isEmpty {
                    StoreEmptyState(symbol: "square.stack.3d.up", title: "No Installed Apps", message: "Apps appear here after Windows Companion confirms them in the paired iPhone inventory.")
                        .padding(.top, 18)
                } else {
                    ForEach(model.inventory.filter(\.isCompanionConfirmed)) { record in
                        InstalledAppCard(
                            record: record,
                            app: model.catalogApps.first { $0.bundleIdentifier.caseInsensitiveCompare(record.canonicalBundleIdentifier) == .orderedSame },
                            busy: model.activeBundleIdentifier == record.canonicalBundleIdentifier,
                            enabled: model.isInventoryLive,
                            uninstall: {
                                selectedForRemoval = record
                                showingRemovalConfirmation = true
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
        }
        .refreshable { await model.load(refresh: true) }
    }

    private var updatesContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if case .cached(let snapshot) = model.inventoryState { savedInventoryNotice(snapshot.lastChecked) }
                if model.state == .offlineCached { OfflineNotice() }
                if model.updates.isEmpty {
                    StoreEmptyState(
                        symbol: model.updateCheckIsFresh ? "checkmark.circle" : "wifi.slash",
                        title: model.updateCheckIsFresh ? "No Updates Available" : "Update Check Needed",
                        message: model.inventory.isEmpty
                            ? "Pair Windows Companion to check real installed apps."
                            : (model.updateCheckIsFresh ? "No newer published releases are available for the current update channel." : "Connect to the internet and refresh to check the latest published releases.")
                    )
                        .padding(.top, 18)
                } else {
                    ForEach(model.updates) { update in
                        LibraryUpdateCard(update: update, enabled: model.canPerformStoreOperations && isCompatible(update.latestVersion.minimumOSVersion)) {
                            Task { await model.update(update) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
        }
        .refreshable { await model.load(refresh: true) }
    }

    private var downloadedContent: some View {
        VStack(spacing: 10) {
            if !handoffHistory.handedOffPackages.isEmpty {
                NavigationLink {
                    HandedOffPackagesList(historyStore: handoffHistory)
                } label: {
                    Label("Handed Off Packages", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain).padding(.horizontal, 20)
            }
            DownloadedPackagesView(manager: downloadManager)
        }
    }

    private var recentlyUpdatedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.recentlyUpdated.isEmpty {
                    StoreEmptyState(symbol: "clock.arrow.circlepath", title: "No Recent Changes", message: "Confirmed updates and signing refreshes will appear here.")
                        .padding(.top, 18)
                } else {
                    ForEach(model.recentlyUpdated) { record in
                        HStack(spacing: 12) {
                            Image(systemName: record.result == .updated ? "arrow.down.circle.fill" : "arrow.clockwise.circle.fill")
                                .font(.title2).foregroundStyle(StorePalette.accent).frame(width: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.appName).font(.headline).lineLimit(1)
                                Text(record.result == .updated ? "\(record.oldVersion) → \(record.newVersion)" : "Signing refreshed · \(record.newVersion)")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(record.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(14).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
        }
    }

    private func savedInventoryNotice(_ date: Date) -> some View {
        Label("Last checked \(date.formatted(date: .abbreviated, time: .shortened)) · showing saved inventory", systemImage: "wifi.slash")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("Windows Companion offline. Last checked \(date.formatted(date: .abbreviated, time: .shortened)). Showing saved inventory.")
    }
}

private struct InstalledAppCard: View {
    let record: InstalledAppRecord
    let app: StoreApp?
    let busy: Bool
    let enabled: Bool
    let uninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteStoreImage(url: app?.iconURL, cornerRadius: 15).frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(app?.name ?? record.canonicalBundleIdentifier).font(.headline).lineLimit(1)
                Text("Version \(record.version ?? "—") · Build \(record.build ?? "—")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("Installed via DreyzeStore Companion").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button(role: .destructive, action: uninstall) { Label("Uninstall", systemImage: "trash") }
                if let expiration = record.provisionExpiration {
                    Text(expiration <= Date() ? "Signing expired" : "Signing expires \(expiration.formatted(date: .abbreviated, time: .omitted))")
                }
            } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary) }
            }
            .disabled(busy || !enabled)
            .accessibilityLabel("Actions for \(app?.name ?? record.canonicalBundleIdentifier)")
        }
        .padding(13).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct LibraryUpdateCard: View {
    let update: UpdateAvailable
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteStoreImage(url: update.app.iconURL, cornerRadius: 15).frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(update.app.name).font(.headline).lineLimit(1)
                Text("\(update.installedVersion) → \(update.latestVersion.version)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Update", action: action).buttonStyle(.borderedProminent).tint(StorePalette.accent).disabled(!enabled)
        }
        .padding(13).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private func isCompatible(_ minimumOSVersion: String) -> Bool {
    guard let required = SemanticVersion(minimumOSVersion) else { return false }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    guard let current = SemanticVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)") else { return false }
    return required <= current
}

private struct HandedOffPackagesList: View {
    @ObservedObject var historyStore: InstallationHistoryStore
    var body: some View {
        List(historyStore.handedOffPackages) { package in
            HStack(spacing: 12) {
                RemoteStoreImage(url: package.iconURL, cornerRadius: 14).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(package.name).font(.headline).lineLimit(1)
                    Text("Version \(package.version) · \(package.sourceName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("Handed off · not confirmed installed").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .listRowBackground(StorePalette.surface)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle("Handed Off").navigationBarTitleDisplayMode(.inline)
    }
}
