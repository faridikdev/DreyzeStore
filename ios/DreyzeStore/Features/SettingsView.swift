import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        StoreMark(size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("DreyzeStore").font(.headline)
                            Text("Discover apps from sources you trust.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                Section("General") {
                    NavigationLink { AppearanceSettingsView() } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                    NavigationLink { SimpleSettingsView(title: "Downloads", symbol: "arrow.down.to.line", message: "Download progress is shown while a package is being prepared. Verified packages are available in Library.") } label: { Label("Downloads", systemImage: "arrow.down.to.line") }
                }
                Section("Store") {
                    NavigationLink { InstallationSettingsView() } label: { Label("Installation", systemImage: "square.and.arrow.down") }
                    NavigationLink { SimpleSettingsView(title: "Sources", symbol: "externaldrive.connected.to.line.below", message: "This build reads the configured DreyzeStore catalog. Adding and managing repositories will be available in a later phase.") } label: { Label("Sources", systemImage: "externaldrive.connected.to.line.below") }
                    NavigationLink { StorageSettingsView() } label: { Label("Storage", systemImage: "internaldrive") }
                }
                Section("Privacy & Security") {
                    NavigationLink { SimpleSettingsView(title: "Security", symbol: "checkmark.shield", message: "A matching SHA-256 confirms file integrity against published metadata. It does not prove that an app is safe.") } label: { Label("Security", systemImage: "checkmark.shield") }
                }
                Section("About") {
                    NavigationLink { AboutSettingsView() } label: { Label("About DreyzeStore", systemImage: "info.circle") }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .tint(StorePalette.accent)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("dreyze.appearance") private var appearance = "system"
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }.pickerStyle(.inline)
            Section { Text("System appearance follows your iPhone settings. Text size and Reduce Motion follow Accessibility settings.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SimpleSettingsView: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(StorePalette.accent)
                .frame(width: 84, height: 84).background(StorePalette.accent.opacity(0.1), in: Circle())
            Text(message).font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 330)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(StorePalette.canvas)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

private struct StorageSettingsView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var showingResult = false
    @State private var showingDeleteConfirmation = false
    @State private var resultMessage = ""
    @State private var usage = PackageStorageUsage(downloadedPackages: 0, temporaryFiles: 0, cache: 0)

    var body: some View {
        List {
            Section("Downloaded Packages") {
                LabeledContent("Packages", value: ByteCountFormatter.string(fromByteCount: usage.downloadedPackages, countStyle: .file))
                Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                    Label("Delete Downloaded Packages", systemImage: "trash")
                }
                .disabled(usage.downloadedPackages == 0)
            }
            Section("Cache") {
                LabeledContent("Cache", value: ByteCountFormatter.string(fromByteCount: usage.cache, countStyle: .file))
                Text("Catalog metadata expires after 7 days. The image cache is limited to 96 MB on disk.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(role: .destructive) { Task { await clearCache() } } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
                .disabled(usage.cache == 0)
            }
            Section("Temporary Files") {
                LabeledContent("Temporary Files", value: ByteCountFormatter.string(fromByteCount: usage.temporaryFiles, countStyle: .file))
                Text("Only inactive DreyzeStore-managed transfer files are removed.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { cleanTemporaryFiles() } label: { Label("Clean Temporary Files", systemImage: "broom") }
                    .disabled(usage.temporaryFiles == 0)
            }
            Section("Total") {
                LabeledContent("DreyzeStore Storage", value: ByteCountFormatter.string(fromByteCount: usage.total, countStyle: .file))
            }
        }
        .navigationTitle("Storage").navigationBarTitleDisplayMode(.inline)
        .alert("Store Cache", isPresented: $showingResult) { Button("OK", role: .cancel) { } } message: { Text(resultMessage) }
        .confirmationDialog("Delete Downloaded Packages?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete All Packages", role: .destructive) {
                do {
                    try downloadManager.deleteAllDownloadedPackages()
                    resultMessage = "Downloaded packages were deleted."
                } catch {
                    resultMessage = "Some packages could not be deleted. Please try again."
                }
                showingResult = true
                Task { await refreshUsage() }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes only verified package files managed by DreyzeStore.") }
        .task { await refreshUsage() }
    }

    private func refreshUsage() async {
        let metadataBytes = await FileCatalogSnapshotStore().storageBytes()
        let imageBytes = await RemoteImageService.shared.diskCacheUsage()
        usage = downloadManager.storageUsage(cacheBytes: metadataBytes + imageBytes)
    }

    private func clearCache() async {
        do {
            try await FileCatalogSnapshotStore().clear()
            await RemoteImageService.shared.clearCache()
            resultMessage = "Cached catalog metadata and images were cleared."
        } catch {
            resultMessage = "The cache could not be fully cleared. Please try again."
        }
        showingResult = true
        await refreshUsage()
    }

    private func cleanTemporaryFiles() {
        do {
            let removed = try downloadManager.cleanTemporaryFiles()
            resultMessage = "Cleaned \(ByteCountFormatter.string(fromByteCount: removed, countStyle: .file)) of inactive temporary files."
        } catch {
            resultMessage = "Temporary files could not be cleaned. Please try again."
        }
        showingResult = true
        Task { await refreshUsage() }
    }
}

private struct AboutSettingsView: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    StoreMark(size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DreyzeStore").font(.title3.bold())
                        Text("Version \(version) (\(build))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Project") {
                Link(destination: URL(string: "https://github.com/faridikdev/DreyzeStore")!) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                NavigationLink("Licenses & Acknowledgements") { LicenseAcknowledgementsView() }
                NavigationLink("Privacy") { SimpleSettingsView(title: "Privacy", symbol: "hand.raised", message: "The store requests public catalog metadata from the API configured for this build. Search history is stored locally on this device.") }
            }
        }
        .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseAcknowledgementsView: View {
    private let zipFoundationLicense = """
    MIT License

    Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

    var body: some View {
        List {
            Section("DreyzeStore") {
                Text("The DreyzeStore client and service code are distributed under the repository MIT license.")
            }
            Section("ZIPFoundation 0.9.20") {
                Text("Used to inspect ZIP/IPA entry metadata without extracting untrusted package paths.")
                Text(zipFoundationLicense)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Link("ZIPFoundation upstream", destination: URL(string: "https://github.com/weichsel/ZIPFoundation")!)
            }
            Section {
                Text("No TrollStore source or installer backend is included.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
