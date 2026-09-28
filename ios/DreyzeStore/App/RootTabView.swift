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
    @AppStorage("dreyze.onboarding.completed.v1") private var onboardingCompleted = false
    @State private var showingOnboarding = false
    @State private var showingCompanionPairing = false

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
                .tabItem { Label("Today", systemImage: "sparkles").accessibilityIdentifier("tab.today") }
            NavigationStack { AppsView(repository: environment.repository) }
                .tabItem { Label("Apps", systemImage: "square.grid.2x2").accessibilityIdentifier("tab.apps") }
            NavigationStack { SearchView(repository: environment.repository) }
                .tabItem { Label("Search", systemImage: "magnifyingglass").accessibilityIdentifier("tab.search") }
            NavigationStack { UpdatesView(repository: environment.repository) }
                .tabItem { Label("Updates", systemImage: "arrow.down.circle").accessibilityIdentifier("tab.updates") }
            NavigationStack { LibraryView(repository: environment.repository) }
                .tabItem { Label("Library", systemImage: "square.stack").accessibilityIdentifier("tab.library") }
        }
        .tint(StorePalette.accent)
        .preferredColorScheme(preferredScheme)
        .task {
            if !onboardingCompleted { showingOnboarding = true }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            DreyzeOnboardingView { shouldPair in
                onboardingCompleted = true
                showingOnboarding = false
                if shouldPair {
                    Task { @MainActor in
                        await Task.yield()
                        showingCompanionPairing = true
                    }
                }
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingCompanionPairing) {
            NavigationStack { WindowsCompanionPairingView() }
        }
    }
}
