import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "sparkles") }

            AppsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            UpdatesView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }

            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack") }
        }
        .tint(Color(red: 0.34, green: 0.32, blue: 0.78))
    }
}
