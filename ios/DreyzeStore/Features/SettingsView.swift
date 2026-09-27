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
                    NavigationLink { SimpleSettingsView(title: "Downloads", symbol: "arrow.down.to.line", message: "Download management will be available when the verified package pipeline is implemented.") } label: { Label("Downloads", systemImage: "arrow.down.to.line") }
                }
                Section("Store") {
                    NavigationLink { SimpleSettingsView(title: "Installation", symbol: "square.and.arrow.down", message: "No installation backend is connected in this version. DreyzeStore will show only methods supported by your device when one is configured.") } label: { Label("Installation", systemImage: "square.and.arrow.down") }
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
    @State private var showingResult = false
    @State private var resultMessage = ""
    var body: some View {
        List {
            Section {
                Text("Catalog information is cached for up to 7 days. Image cache is limited to 96 MB on disk.").font(.footnote).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task {
                        do {
                            try await FileCatalogSnapshotStore().clear()
                            await RemoteImageService.shared.clearCache()
                            resultMessage = "Cached catalog metadata and images were cleared."
                        } catch {
                            resultMessage = "The catalog cache could not be fully cleared. Please try again."
                        }
                        showingResult = true
                    }
                } label: { Label("Clear Cached Store Data", systemImage: "trash") }
            }
        }
        .navigationTitle("Storage").navigationBarTitleDisplayMode(.inline)
        .alert("Store Cache", isPresented: $showingResult) { Button("OK", role: .cancel) { } } message: { Text(resultMessage) }
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
                NavigationLink("Licenses & Acknowledgements") { SimpleSettingsView(title: "Licenses", symbol: "doc.text", message: "DreyzeStore client code is distributed under the repository license. No third-party installer implementation is included in this build.") }
                NavigationLink("Privacy") { SimpleSettingsView(title: "Privacy", symbol: "hand.raised", message: "The store requests public catalog metadata from the API configured for this build. Search history is stored locally on this device.") }
            }
        }
        .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
}
