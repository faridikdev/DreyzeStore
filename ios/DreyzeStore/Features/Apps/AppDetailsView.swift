import SwiftUI

struct AppDetailsView: View {
    @StateObject private var model: AppDetailsViewModel
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var inventory = InstalledInventoryService.shared
    @State private var selectedScreenshot: AppScreenshot?
    @State private var showDownloadSheet = false

    init(repository: (any StoreRepository)?, appID: String) {
        _model = StateObject(wrappedValue: AppDetailsViewModel(repository: repository, appID: appID))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                ScrollView { VStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in StoreSkeletonCard() } }.padding(20) }
            case .loading where model.app == nil:
                ScrollView { VStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in StoreSkeletonCard() } }.padding(20) }
            case .error(let message) where model.app == nil:
                StoreLoadError(title: "Couldn’t Load App", message: message) { Task { await model.load() } }.padding(20)
            default:
                if let app = model.app { details(app) }
            }
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() } }
        .task {
            async let appLoad: Void = model.load()
            _ = await inventory.synchronize()
            await appLoad
        }
        .sheet(isPresented: $showDownloadSheet) {
            if let app = model.app { DownloadFlowSheet(app: app, manager: downloadManager) }
        }
        .fullScreenCover(item: $selectedScreenshot) { screenshot in
            ScreenshotGallery(screenshots: model.app?.screenshots ?? [], initial: screenshot)
        }
    }

    private func details(_ app: StoreApp) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if model.state == .offlineCached { OfflineNotice() }
                header(app)
                if let screenshots = app.screenshots, !screenshots.isEmpty { screenshotRail(screenshots) }
                if let description = app.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        StoreSectionHeading(title: "About This App")
                        Text(description).font(.body).foregroundStyle(.primary.opacity(0.82)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                if !app.currentVersion.releaseNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        StoreSectionHeading(title: "What’s New", eyebrow: app.currentVersion.version)
                        Text(app.currentVersion.releaseNotes).font(.body).foregroundStyle(.primary.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .cached(let snapshot) = inventory.state,
                   snapshot.records.contains(where: { $0.canonicalBundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame }) {
                    Label("Companion last checked \(snapshot.lastChecked.formatted(date: .abbreviated, time: .shortened)). Refresh status before installing or updating.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                packageInformation(app)
                if !model.versions.isEmpty { versionHistory }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 42)
        }
        .refreshable { await model.load(refresh: true) }
        .navigationTitle(app.name)
    }

    private func header(_ app: StoreApp) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                RemoteStoreImage(url: app.iconURL, cornerRadius: 26).frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.title2.bold()).tracking(-0.5).fixedSize(horizontal: false, vertical: true)
                    Text(app.developer.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Text(app.category.name).font(.caption.weight(.medium)).foregroundStyle(StorePalette.accent)
                }
                Spacer(minLength: 0)
            }
            Button {
                if isInventoryCached(for: app) {
                    Task { _ = await inventory.synchronize() }
                } else if !isInstalledAndCurrent(app) {
                    showDownloadSheet = true
                }
            } label: {
                HStack(spacing: 8) { Image(systemName: actionSymbol(for: app)); Text(downloadTitle(for: app)) }
                    .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(isInstalledAndCurrent(app) ? StorePalette.accent : .white)
                    .background(isInstalledAndCurrent(app) ? StorePalette.accent.opacity(0.12) : StorePalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isInstalledAndCurrent(app))
            .accessibilityHint(actionHint(for: app))
            .accessibilityIdentifier("appDetails.primaryAction")
            HStack(spacing: 0) {
                AppFact(title: "VERSION", value: app.currentVersion.version)
                AppFact(title: "REQUIRES", value: "iOS \(app.currentVersion.minimumOSVersion)")
                AppFact(title: "SIZE", value: ByteCountFormatter.string(fromByteCount: app.currentVersion.size, countStyle: .file))
            }
            .padding(.vertical, 14)
            .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func downloadTitle(for app: StoreApp) -> String {
        if isInventoryCached(for: app) { return "CHECK STATUS" }
        if let record = confirmedRecord(for: app) {
            return VersionComparator.isNewerRelease(
                candidateVersion: app.currentVersion.version,
                candidateBuild: app.currentVersion.build,
                installedVersion: record.version ?? "",
                installedBuild: record.build
            ) ? "UPDATE" : "INSTALLED"
        }
        switch downloadManager.state(for: app) {
        case .preparing, .downloading: "DOWNLOADING"
        case .verifying: "VERIFYING"
        case .inspecting: "INSPECTING"
        case .ready: "READY"
        case .failed: "RETRY"
        case .idle, .cancelled: "GET"
        }
    }

    private func actionSymbol(for app: StoreApp) -> String {
        switch downloadTitle(for: app) {
        case "UPDATE": "arrow.clockwise"
        case "INSTALLED": "checkmark"
        case "CHECK STATUS": "arrow.clockwise"
        case "READY": "checkmark.shield"
        default: "arrow.down.to.line"
        }
    }

    private func actionHint(for app: StoreApp) -> String {
        switch downloadTitle(for: app) {
        case "UPDATE": "Downloads and verifies the newer release, then offers installation through a ready Windows Companion."
        case "INSTALLED": "Windows Companion confirmed this installed version from the connected iPhone."
        case "CHECK STATUS": "Refreshes the saved Companion inventory before offering installation actions."
        default: "Downloads and verifies the package. Installation requires a paired and configured Windows Companion."
        }
    }

    private func confirmedRecord(for app: StoreApp) -> InstalledAppRecord? {
        guard case .live(let snapshot) = inventory.state else { return nil }
        return snapshot.records.first {
            $0.source == .companionConfirmed
                && $0.canonicalBundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame
        }
    }

    private func isInstalledAndCurrent(_ app: StoreApp) -> Bool {
        guard let record = confirmedRecord(for: app), let installedVersion = record.version else { return false }
        return !VersionComparator.isNewerRelease(
            candidateVersion: app.currentVersion.version,
            candidateBuild: app.currentVersion.build,
            installedVersion: installedVersion,
            installedBuild: record.build
        )
    }

    private func isInventoryCached(for app: StoreApp) -> Bool {
        guard case .cached(let snapshot) = inventory.state else { return false }
        return snapshot.records.contains {
            $0.source == .companionConfirmed
                && $0.canonicalBundleIdentifier.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame
        }
    }

    private func screenshotRail(_ screenshots: [AppScreenshot]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreSectionHeading(title: "Preview")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(screenshots) { screenshot in
                        Button { selectedScreenshot = screenshot } label: {
                            RemoteStoreImage(url: screenshot.url, cornerRadius: 24, fit: true)
                                .frame(width: 180, height: 330)
                                .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(screenshot.alt)
                        .accessibilityHint("Opens full screen screenshot viewer")
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private func packageInformation(_ app: StoreApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("Package Information") {
            VStack(spacing: 0) {
                MetadataLine(title: "Developer", value: app.developer.name)
                if let websiteURL = app.developer.websiteURL {
                    HStack {
                        Text("Developer Website").foregroundStyle(.secondary)
                        Spacer()
                        Link("Visit Website", destination: websiteURL).lineLimit(1)
                    }.font(.footnote).padding(.horizontal, 14).padding(.vertical, 11)
                }
                MetadataLine(title: "Category", value: app.category.name)
                MetadataLine(title: "Source", value: app.repositoryName)
                MetadataLine(title: "Bundle ID", value: app.bundleIdentifier, monospaced: true)
                MetadataLine(title: "Build", value: app.currentVersion.build)
                MetadataLine(title: "Released", value: app.currentVersion.versionDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                VStack(alignment: .leading, spacing: 7) {
                    Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(app.currentVersion.sha256.lowercased()).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Verification checks package integrity and metadata. It does not guarantee that the app is safe.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2).padding(.top, 6)
            }
            .font(.headline)
            .tint(StorePalette.accent)
        }
    }

    private var versionHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreSectionHeading(title: "Version History")
            LazyVStack(spacing: 0) {
                ForEach(Array(model.versions.enumerated()), id: \.element.version) { index, version in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(index == 0 ? StorePalette.accent : StorePalette.accent.opacity(0.35)).frame(width: 9, height: 9)
                            if index < model.versions.count - 1 { Rectangle().fill(StorePalette.accent.opacity(0.18)).frame(width: 1, height: 48) }
                        }.frame(width: 12)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(version.version).font(.headline)
                                if index == 0 { Text("LATEST").font(.caption2.weight(.bold)).foregroundStyle(StorePalette.accent) }
                                Spacer()
                                Text(version.versionDate?.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(version.releaseNotes).font(.subheadline).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, index < model.versions.count - 1 ? 18 : 0)
                    }
                    .padding(.horizontal, 15).padding(.top, 15)
                }
            }
            .padding(.bottom, 14)
            .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct AppFact: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 5) {
            Text(title).font(.caption2.weight(.bold)).tracking(0.45).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }
}

private struct MetadataLine: View {
    let title: String
    let value: String
    var monospaced = false
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
        }.font(.footnote).padding(.horizontal, 14).padding(.vertical, 11)
    }
}

private struct ScreenshotGallery: View {
    let screenshots: [AppScreenshot]
    let initial: AppScreenshot
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String
    init(screenshots: [AppScreenshot], initial: AppScreenshot) {
        self.screenshots = screenshots
        self.initial = initial
        _selection = State(initialValue: initial.id)
    }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(screenshots) { screenshot in
                    RemoteStoreImage(url: screenshot.url, cornerRadius: 0, fit: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 8)
                        .tag(screenshot.id).accessibilityLabel(screenshot.alt)
                }
            }.tabViewStyle(.page(indexDisplayMode: .always))
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 12).padding(.trailing, 18).accessibilityLabel("Close screenshot viewer")
        }
        .statusBarHidden()
    }
}
