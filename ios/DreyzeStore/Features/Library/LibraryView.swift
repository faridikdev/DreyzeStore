import SwiftUI

private enum LibrarySection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case downloaded = "Downloaded"
    case updates = "Updates"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .installed: "square.stack.3d.up"; case .downloaded: "arrow.down.circle"; case .updates: "arrow.triangle.2.circlepath" }
    }
    var title: String {
        switch self { case .installed: "No Installed Apps"; case .downloaded: "No Downloads"; case .updates: "No Updates Yet" }
    }
    var message: String {
        switch self {
        case .installed: "Installed app inventory becomes available with a supported installation backend."
        case .downloaded: "Packages you explicitly download will appear here in a later phase."
        case .updates: "Updates will appear when DreyzeStore can read a real installed app inventory."
        }
    }
}

struct LibraryView: View {
    @State private var selection: LibrarySection = .installed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 18) {
            Picker("Library", selection: $selection) {
                ForEach(LibrarySection.allCases) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 10)
            Spacer(minLength: 0)
            StoreEmptyState(symbol: selection.symbol, title: selection.title, message: selection.message)
            Spacer(minLength: 0)
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection)
    }
}
