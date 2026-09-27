import AVFoundation
import SwiftUI

struct WindowsCompanionPairingView: View {
    @State private var endpoint = ""
    @State private var pairingCode = ""
    @State private var fingerprint = ""
    @State private var pairedRecord = WindowsCompanionPairingStore.load()
    @State private var isPairing = false
    @State private var isRefreshing = false
    @State private var isScanning = false
    @State private var cameraMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Label("A computer on your local network signs the verified package and installs it over USB.", systemImage: "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Apple credentials stay on the Windows PC. The DreyzeStore catalog server is not part of pairing or signing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let pairedRecord {
                Section("Paired Computer") {
                    LabeledContent("Computer", value: pairedRecord.endpoint.host ?? "Windows Companion")
                    LabeledContent("iPhone", value: pairedRecord.deviceName ?? "Not connected")
                    LabeledContent("iOS", value: pairedRecord.deviceProductVersion ?? "Unknown")
                    LabeledContent("Trust", value: pairedRecord.deviceUDID == nil ? "Connect and trust iPhone" : "Trusted")
                    LabeledContent("Developer Mode", value: developerModeLabel(pairedRecord.developerMode))
                    LabeledContent("Signing", value: pairedRecord.signingConfigured ? "Configured" : "Needs setup")
                    Button {
                        Task { await refreshPairing() }
                    } label: {
                        Label(isRefreshing ? "Checking…" : "Test Connection", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    Button("Forget This Computer", role: .destructive) {
                        WindowsCompanionPairing.forget()
                        self.pairedRecord = nil
                    }
                }
            } else {
                Section("Pair with Windows") {
                    Button {
                        requestCameraAndScan()
                    } label: {
                        Label("Scan Companion QR Code", systemImage: "qrcode.viewfinder")
                    }
                    TextField("Local HTTPS endpoint", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("One-time pairing code", text: $pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                    TextField("TLS certificate SHA-256", text: $fingerprint, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...3)
                        .font(.system(.caption, design: .monospaced))
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            Spacer()
                            if isPairing { ProgressView().padding(.trailing, 8) }
                            Text(isPairing ? "Pairing…" : "Pair Computer")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isPairing || endpoint.isEmpty || pairingCode.isEmpty || fingerprint.isEmpty)
                } footer: {
                    Text("Pair only with a computer you control. The certificate fingerprint pins future connections to this Companion.")
                }
            }

            Section("Before Installing") {
                Label("Connect iPhone by USB and tap Trust on the device.", systemImage: "cable.connector")
                Label("Enable Developer Mode in Settings → Privacy & Security if required.", systemImage: "checkmark.shield")
                Label("Import a matching Apple Development certificate and provisioning profile in Companion.", systemImage: "signature")
                Text("Windows Companion can report installation success only after the connected iPhone lists the exact bundle ID, version, and build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Connect Computer")
        .navigationBarTitleDisplayMode(.inline)
        .tint(StorePalette.accent)
        .sheet(isPresented: $isScanning) {
            NavigationStack {
                WindowsCompanionQRScanner { value in
                    consumeScannedCode(value)
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan Companion QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { isScanning = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Camera Access", isPresented: Binding(
            get: { cameraMessage != nil },
            set: { if !$0 { cameraMessage = nil } }
        )) {
            Button("OK", role: .cancel) { cameraMessage = nil }
        } message: {
            Text(cameraMessage ?? "")
        }
        .task {
            if pairedRecord != nil { await refreshPairing() }
        }
    }

    private func requestCameraAndScan() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isScanning = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { isScanning = true }
                    else { cameraMessage = "Camera access is needed to scan the pairing QR. You can also enter the endpoint, code, and fingerprint manually." }
                }
            }
        case .denied, .restricted:
            cameraMessage = "Allow camera access in Settings, or enter the pairing details manually."
        @unknown default:
            cameraMessage = "Camera access is unavailable. Enter the pairing details manually."
        }
    }

    private func consumeScannedCode(_ value: String) {
        do {
            let payload = try WindowsCompanionPairingPayload.decode(value)
            endpoint = payload.endpoint.absoluteString
            pairingCode = payload.pairingCode
            fingerprint = payload.certificateSHA256
            isScanning = false
            Task { await pair() }
        } catch {
            errorMessage = "That QR code is not a valid DreyzeStore Companion pairing offer."
        }
    }

    @MainActor
    private func pair() async {
        guard !isPairing else { return }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let payload = try WindowsCompanionPairing.manualPayload(endpoint: endpoint, code: pairingCode, fingerprint: fingerprint)
            pairedRecord = try await WindowsCompanionPairing.pair(payloadText: payload)
            pairingCode = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshPairing() async {
        guard !isRefreshing, pairedRecord != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            pairedRecord = try await WindowsCompanionPairing.refresh()
            errorMessage = nil
        } catch {
            errorMessage = "Could not reach the paired Windows Companion. Check that both devices are on the same Wi-Fi network and the Companion is running."
        }
    }

    private func developerModeLabel(_ enabled: Bool?) -> String {
        switch enabled {
        case true: "Enabled"
        case false: "Off"
        case nil: "Not reported by device service"
        }
    }
}
