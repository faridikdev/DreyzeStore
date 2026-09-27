import SwiftUI
import UIKit

struct DownloadFlowSheet: View {
    let app: StoreApp
    @ObservedObject var manager: DownloadManager
    @StateObject private var installationCoordinator: InstallationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showFailureDetails = false
    @State private var showInstallationFailureDetails = false
    @State private var showingInstallConfirmation = false
    @State private var selectedBackendIdentifier = ""

    init(app: StoreApp, manager: DownloadManager) {
        self.app = app
        self.manager = manager
        _installationCoordinator = StateObject(wrappedValue: InstallationCoordinator(storage: manager.storage))
    }

    private var state: PackageDownloadState { manager.state(for: app) }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle:
                    confirmation
                case .preparing:
                    progressState(title: "Preparing Download", message: "Checking storage and preparing a secure temporary file.", symbol: "arrow.down.to.line") {
                        cancelButton
                    }
                case .downloading(let progress):
                    progressState(title: "Downloading", message: "\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.expectedBytes, countStyle: .file))", symbol: "arrow.down.circle") {
                        VStack(spacing: 18) {
                            CircularDownloadProgress(fractionCompleted: progress.fractionCompleted)
                                .frame(width: 96, height: 96)
                            cancelButton
                        }
                    }
                case .verifying:
                    progressState(title: "Verifying Package", message: "Checking the downloaded file against its published SHA-256 checksum.", symbol: "checkmark.shield") {
                        cancelButton
                    }
                case .inspecting:
                    progressState(title: "Inspecting Package", message: "Validating the archive structure and app metadata.", symbol: "doc.text.magnifyingglass") {
                        cancelButton
                    }
                case .ready(let package):
                    readyState(package)
                case .failed(let failure):
                    failureState(failure)
                case .cancelled:
                    progressState(title: "Download Cancelled", message: "The temporary package was removed.", symbol: "xmark.circle") {
                        Button("Download Again") { manager.retry(app: app) }
                            .buttonStyle(.borderedProminent).tint(StorePalette.accent)
                        Button("Done", role: .cancel) { dismiss() }.buttonStyle(.bordered)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StorePalette.canvas.ignoresSafeArea())
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }.disabled(state.isActive)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await installationCoordinator.refreshBackendOptions()
            if selectedBackendIdentifier.isEmpty {
                selectedBackendIdentifier = installationCoordinator.automaticBackendIdentifier() ?? ""
            }
        }
        .sheet(isPresented: Binding(
            get: { installationCoordinator.pendingHandoffPackage != nil },
            set: { presented in
                if !presented, case .awaitingHandoff = installationCoordinator.state {
                    installationCoordinator.completeExternalHandoff(completed: false, destination: nil, error: nil)
                }
            }
        )) {
            if let package = installationCoordinator.pendingHandoffPackage {
                ExternalPackageShareSheet(package: package) { destination, completed, error in
                    installationCoordinator.completeExternalHandoff(completed: completed, destination: destination, error: error)
                }
                .ignoresSafeArea()
            }
        }
    }

    private var sheetTitle: String {
        switch state {
        case .ready: "Package Ready"
        case .downloading, .verifying, .inspecting, .preparing: "Download"
        default: "Get App"
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                RemoteStoreImage(url: app.iconURL, cornerRadius: 20).frame(width: 68, height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download \"\(app.name)\"?").font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(app.developer.name).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                detailLine("Version", app.currentVersion.version)
                detailLine("Developer", app.developer.name)
                detailLine("Size", ByteCountFormatter.string(fromByteCount: app.currentVersion.size, countStyle: .file))
                detailLine("Source", app.repositoryName)
            }
            .padding(.horizontal, 14)
            .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("The package will be verified before it is saved. Downloading does not install the app.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Download") { manager.start(app: app) }
                    .buttonStyle(.borderedProminent).tint(StorePalette.accent).frame(maxWidth: .infinity)
                    .accessibilityHint("Downloads and verifies the package. It does not install it.")
            }
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.footnote)
        .padding(.vertical, 10)
    }

    private func progressState<Actions: View>(title: String, message: String, symbol: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(StorePalette.accent)
                .frame(width: 88, height: 88).background(StorePalette.accent.opacity(0.10), in: Circle())
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if state.isActive, case .downloading = state { EmptyView() }
            else if state.isActive { ProgressView().tint(StorePalette.accent).padding(.top, 4) }
            actions()
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cancelButton: some View {
        Button("Cancel Download", role: .destructive) { manager.cancel(app: app) }
            .buttonStyle(.bordered).accessibilityHint("Cancels the transfer and removes its temporary file.")
    }

    @ViewBuilder
    private func readyState(_ package: VerifiedPackage) -> some View {
        switch installationCoordinator.state {
        case .ready:
            if showingInstallConfirmation { installationConfirmation(package) }
            else { packageReady(package) }
        case .preparingInstallation:
            progressState(title: "Preparing Installation", message: "Rechecking the saved checksum and IPA metadata.", symbol: "checkmark.shield") {
                Button("Cancel", role: .cancel) { installationCoordinator.cancel() }.buttonStyle(.bordered)
            }
        case .installing:
            progressState(title: "Preparing Handoff", message: "The verified package is being prepared for the selected method.", symbol: "square.and.arrow.up") {
                Button("Cancel", role: .cancel) { installationCoordinator.cancel() }.buttonStyle(.bordered)
            }
        case .awaitingHandoff:
            progressState(title: "Choose a Destination", message: "The system share sheet will hand off this verified IPA. DreyzeStore cannot confirm that the receiving app installs it.", symbol: "square.and.arrow.up") {
                Button("Cancel", role: .cancel) { installationCoordinator.cancel() }.buttonStyle(.bordered)
            }
        case .handedOff(let receipt):
            outcomeState(title: "Handed Off", message: "The package was handed to \(receipt.destination ?? receipt.method). Installation was not confirmed.", symbol: "checkmark.circle.fill", isSuccess: true)
        case .installed(let installed):
            outcomeState(title: "Installed", message: "\(installed.bundleIdentifier) version \(installed.version) was confirmed by the installation backend.", symbol: "checkmark.circle.fill", isSuccess: true)
        case .failed(let failure), .unsupported(let failure):
            installationFailureState(failure)
        case .cancelled:
            outcomeState(title: "Handoff Cancelled", message: "No installation was reported.", symbol: "xmark.circle", isSuccess: false) {
                Button("Back to Package") {
                    showingInstallConfirmation = false
                    installationCoordinator.reset()
                }.buttonStyle(.borderedProminent).tint(StorePalette.accent)
            }
        }
    }

    private func packageReady(_ package: VerifiedPackage) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 48)).foregroundStyle(StorePalette.accent)
                .frame(width: 92, height: 92).background(StorePalette.accent.opacity(0.1), in: Circle())
            Text("Package Ready").font(.title2.bold())
            Text("Package downloaded and verified.").font(.body).foregroundStyle(.secondary)
            Text("Installation method: \(installationCoordinator.availableBackendOptions.first(where: { $0.identifier == selectedBackendIdentifier })?.displayName ?? "Not available")")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let record = manager.packages.first(where: { $0.id == package.localURL.deletingPathExtension().lastPathComponent }) {
                NavigationLink("View Package Details") { DownloadedPackageDetailsView(package: record) }
                    .buttonStyle(.bordered)
            }
            Button("Install") {
                showingInstallConfirmation = true
            }
            .buttonStyle(.borderedProminent).tint(StorePalette.accent)
            .disabled(installationCoordinator.availableBackendOptions.isEmpty)
            Button("Done") { dismiss() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installationConfirmation(_ package: VerifiedPackage) -> some View {
        let available = installationCoordinator.availableBackendOptions
        return VStack(alignment: .leading, spacing: 18) {
            Text("Install “\(app.name)”?").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                detailLine("Version", package.version)
                detailLine("Bundle ID", package.bundleIdentifier)
                detailLine("Developer", app.developer.name)
                detailLine("Size", ByteCountFormatter.string(fromByteCount: package.size, countStyle: .file))
                detailLine("Source", app.repositoryName)
                detailLine("Installation Method", available.first(where: { $0.identifier == selectedBackendIdentifier })?.displayName ?? "Unavailable")
            }
            .padding(.horizontal, 14)
            .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Package verified. Sharing it to another app does not confirm installation.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if available.count > 1 {
                Picker("Installation Method", selection: $selectedBackendIdentifier) {
                    ForEach(available) { option in Text(option.displayName).tag(option.identifier) }
                }
                .pickerStyle(.menu)
            }
            if available.isEmpty {
                StoreEmptyState(symbol: "exclamationmark.shield", title: "No Available Method", message: "No installation or handoff method is available in this environment.")
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { showingInstallConfirmation = false }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Install") {
                    Task { await installationCoordinator.beginInstall(package: package, backendIdentifier: selectedBackendIdentifier.isEmpty ? installationCoordinator.automaticBackendIdentifier() : selectedBackendIdentifier) }
                }
                .buttonStyle(.borderedProminent).tint(StorePalette.accent).frame(maxWidth: .infinity)
                .disabled(available.isEmpty || selectedBackendIdentifier.isEmpty)
            }
        }
        .frame(maxWidth: 380, maxHeight: .infinity, alignment: .topLeading)
    }

    private func outcomeState<Actions: View>(title: String, message: String, symbol: String, isSuccess: Bool, @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(isSuccess ? StorePalette.accent : Color.secondary)
                .frame(width: 92, height: 92).background(StorePalette.accent.opacity(0.1), in: Circle())
            Text(title).font(.title2.bold())
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            actions()
            Button("Done") { dismiss() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installationFailureState(_ failure: InstallationFailure) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 44)).foregroundStyle(.orange)
                .frame(width: 88, height: 88).background(.orange.opacity(0.10), in: Circle())
            Text(failure.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(failure.userMessage).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Show Details", isExpanded: $showInstallationFailureDetails) {
                Text(failure.technicalDetails).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
            }
            .font(.footnote).tint(StorePalette.accent)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("Done") { dismiss() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Try Again") {
                    showingInstallConfirmation = true
                    installationCoordinator.reset()
                }.buttonStyle(.borderedProminent).tint(StorePalette.accent).frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ failure: PackageDownloadFailure) -> some View {
        VStack(spacing: 16) {
            Image(systemName: failure.code == .checksumMismatch ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
                .frame(width: 88, height: 88).background(.orange.opacity(0.10), in: Circle())
            Text(failure.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(failure.userMessage).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Show Details", isExpanded: $showFailureDetails) {
                Text(failure.technicalDetails).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
            }
            .font(.footnote).tint(StorePalette.accent)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("Done") { dismiss() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Retry") { manager.retry(app: app) }.buttonStyle(.borderedProminent).tint(StorePalette.accent).frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CircularDownloadProgress: View {
    let fractionCompleted: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(StorePalette.accent.opacity(0.14), lineWidth: 8)
            Circle()
                .trim(from: 0, to: fractionCompleted)
                .stroke(StorePalette.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: fractionCompleted)
            Text("\(Int(fractionCompleted * 100))%")
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.identity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(fractionCompleted * 100)) percent")
    }
}

struct DownloadedPackagesView: View {
    @ObservedObject var manager: DownloadManager
    @State private var packageToDelete: StoredVerifiedPackage?
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if manager.packages.isEmpty {
                StoreEmptyState(symbol: "arrow.down.circle", title: "No Downloads", message: "Apps you download and verify will appear here.")
                    .padding(.horizontal, 24)
            } else {
                List(manager.packages) { package in
                    NavigationLink { DownloadedPackageDetailsView(package: package) } label: {
                        packageRow(package)
                    }
                    .listRowBackground(StorePalette.surface)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            packageToDelete = package
                            showingDeleteConfirmation = true
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { manager.refreshPackages() }
            }
        }
        .task { manager.refreshPackages() }
        .confirmationDialog("Delete Downloaded Package?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let packageToDelete else { return }
                do { try manager.deletePackage(packageToDelete) }
                catch { errorMessage = "The package could not be deleted. Please try again." }
            }
            Button("Cancel", role: .cancel) { packageToDelete = nil }
        } message: { Text("\(packageToDelete?.name ?? "This package") will be removed from DreyzeStore.") }
        .alert("Couldn’t Delete Package", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func packageRow(_ package: StoredVerifiedPackage) -> some View {
        HStack(spacing: 13) {
            RemoteStoreImage(url: package.iconURL, cornerRadius: 16).frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(package.name).font(.headline).lineLimit(1)
                Text("Version \(package.version) · \(package.sourceName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Label("Verified · \(ByteCountFormatter.string(fromByteCount: package.size, countStyle: .file))", systemImage: "checkmark.shield.fill")
                    .font(.caption2.weight(.medium)).foregroundStyle(StorePalette.accent).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct DownloadedPackageDetailsView: View {
    let package: StoredVerifiedPackage
    @State private var copied = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    RemoteStoreImage(url: package.iconURL, cornerRadius: 20).frame(width: 70, height: 70)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                        Text("Verified package").font(.subheadline).foregroundStyle(StorePalette.accent)
                    }
                }.padding(.vertical, 5)
            }
            Section("Package") {
                value("Bundle ID", package.bundleIdentifier, monospaced: true)
                value("Version", package.version)
                value("Build", package.build)
                value("Minimum iOS", package.minimumOSVersion)
                value("Size", ByteCountFormatter.string(fromByteCount: package.size, countStyle: .file))
                value("Source", package.sourceName)
                value("Verified", package.verifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("SHA-256") {
                Text(package.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button {
                    UIPasteboard.general.string = package.sha256
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy SHA-256", systemImage: copied ? "checkmark" : "doc.on.doc") }
            }
        }
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func value(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
        }
    }
}
