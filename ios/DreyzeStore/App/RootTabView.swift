import SwiftUI

@MainActor
final class StoreEnvironment: ObservableObject {
    let repository: (any StoreRepository)?
    let configurationError: String?

    init() {
        do {
            let configuration = try APIConfiguration.from()
            repository = NetworkStoreRepository(client: APIClient(configuration: configuration))
            configurationError = nil
        } catch {
            repository = nil
            configurationError = StoreError.configurationUnavailable.userMessage
        }
    }
}

struct RootTabView: View {
    @StateObject private var environment = StoreEnvironment()
    @AppStorage("dreyze.appearance") private var appearance = "system"

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        TabView {
            NavigationStack { TodayView(repository: environment.repository) }
                .tabItem { Label("Today", systemImage: "sparkles") }
            NavigationStack { AppsView(repository: environment.repository) }
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            NavigationStack { SearchView(repository: environment.repository) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { UpdatesView() }
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "square.stack") }
        }
        .tint(StorePalette.accent)
        .preferredColorScheme(preferredScheme)
    }
}
