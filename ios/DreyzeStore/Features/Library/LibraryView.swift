import SwiftUI

private enum LibrarySection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case downloaded = "Downloaded"
    case handedOff = "Handed Off"
    case updates = "Updates"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .installed: "square.stack.3d.up"; case .downloaded: "arrow.down.circle"; case .handedOff: "square.and.arrow.up"; case .updates: "arrow.triangle.2.circlepath" }
    }
    var title: String {
        switch self { case .installed: "No Installed Apps"; case .downloaded: "No Downloads"; case .handedOff: "No Handed Off Packages"; case .updates: "No Updates Yet" }
    }
    var message: String {
        switch self {
        case .installed: "Installed app inventory becomes available with a supported installation backend."
        case .downloaded: "Packages you download and verify will appear here."
        case .handedOff: "Packages handed to another app appear here. Handoff does not confirm installation."
        case .updates: "Updates will appear when DreyzeStore can read a real installed app inventory."
        }
    }
}

struct LibraryView: View {
    @State private var selection: LibrarySection = .installed
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var historyStore = InstallationHistoryStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 18) {
            Picker("Library", selection: $selection) {
                ForEach(LibrarySection.allCases) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 10)
            if selection == .downloaded {
                DownloadedPackagesView(manager: downloadManager)
            } else if selection == .handedOff {
                HandedOffPackagesView(historyStore: historyStore)
            } else {
                Spacer(minLength: 0)
                StoreEmptyState(symbol: selection.symbol, title: selection.title, message: selection.message)
                Spacer(minLength: 0)
            }
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection)
    }
}

private struct HandedOffPackagesView: View {
    @ObservedObject var historyStore: InstallationHistoryStore

    var body: some View {
        Group {
            if historyStore.handedOffPackages.isEmpty {
                StoreEmptyState(symbol: "square.and.arrow.up", title: "No Handed Off Packages", message: "Packages handed to another app appear here. Handoff does not confirm installation.")
                    .padding(.horizontal, 24)
            } else {
                List(historyStore.handedOffPackages) { package in
                    HStack(spacing: 13) {
                        RemoteStoreImage(url: package.iconURL, cornerRadius: 16).frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name).font(.headline).lineLimit(1)
                            Text("Version \(package.version) · \(package.sourceName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Label("Handed Off · \(package.handedOffAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "square.and.arrow.up")
                                .font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                            Text("Not confirmed as installed").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .listRowBackground(StorePalette.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}
