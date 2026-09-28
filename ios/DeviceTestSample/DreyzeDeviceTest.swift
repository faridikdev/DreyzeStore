import SwiftUI

@main
struct DreyzeDeviceTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.green)
            Text("Dreyze Device Test")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Owner-authorized installation test · RC1")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("org.dreyzestore.test.sample · 0.9.0 · build 1")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
