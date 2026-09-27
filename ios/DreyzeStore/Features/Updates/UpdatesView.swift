import SwiftUI

struct UpdatesView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                StoreEmptyState(symbol: "checkmark.circle", title: "No Updates to Show", message: "Updates will appear here when DreyzeStore can read an installed app inventory.")
                Text("DreyzeStore does not request or invent installed app data in this version.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            }.padding(.top, 26).padding(.horizontal, 20)
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() } }
    }
}
