import SwiftUI

struct InstallationSettingsView: View {
    @StateObject private var coordinator = InstallationCoordinator.shared

    var body: some View {
        List {
            Section {
                Text("Installation methods depend on your device and environment. DreyzeStore reports a confirmed install only when the selected backend can verify it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Methods") {
                ForEach(coordinator.backendOptions) { option in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(option.displayName).font(.body.weight(.medium))
                            Spacer()
                            Text(statusLabel(option.availability))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(option.availability == .available ? StorePalette.accent : Color.secondary)
                        }
                        Text(explanation(option)).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if option.capabilities.contains(.externalHandoff) {
                            Text("Handoff only · installation, inventory, and uninstall are not confirmed")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("Installation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.refreshBackendOptions() }
        .tint(StorePalette.accent)
    }

    private func statusLabel(_ availability: BackendAvailability) -> String {
        switch availability {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .requiresConfiguration: "Setup Required"
        case .unsupported: "Unsupported"
        }
    }

    private func explanation(_ option: InstallationBackendOption) -> String {
        if option.identifier == TrollStoreBackend().identifier {
            return "Uses iOS Open In for the com.apple.itunes.ipa document type. TrollStore or TrollStore Lite can receive the file when installed and registered; select the destination in the system menu. Its installation prompt follows its own settings. DreyzeStore reports Handed Off, not Installed."
        }
        switch option.availability {
        case .available: "The system share sheet can hand the verified IPA to another app. This does not mean the app was installed."
        case .unavailable(let reason), .requiresConfiguration(let reason), .unsupported(let reason): reason
        }
    }
}
