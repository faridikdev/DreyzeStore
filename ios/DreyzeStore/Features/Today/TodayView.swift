import SwiftUI

struct TodayView: View {
    @StateObject private var model: TodayViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(repository: (any StoreRepository)?) { _model = StateObject(wrappedValue: TodayViewModel(repository: repository)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if model.state == .offlineCached { OfflineNotice() }
                switch model.state {
                case .idle:
                    VStack(spacing: 12) { ForEach(0..<3, id: \.self) { _ in StoreSkeletonCard() } }
                case .loading where model.sections.isEmpty && model.newReleases.isEmpty:
                    VStack(spacing: 12) { ForEach(0..<3, id: \.self) { _ in StoreSkeletonCard() } }
                case .error(let message) where model.sections.isEmpty && model.newReleases.isEmpty:
                    StoreLoadError(title: "Couldn’t Load Store", message: message) { Task { await model.load(refresh: true) } }
                default:
                    content
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() } }
        .refreshable { await model.load(refresh: true) }
        .task { await model.load() }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88), value: model.state)
    }

    @ViewBuilder private var content: some View {
        let hero = model.sections.first(where: { $0.key == "hero" })?.items.first
        if let hero { heroCard(hero) }

        let curated = model.sections.filter { $0.key != "hero" && $0.key != "new-releases" && $0.key != "recently-updated" }
        ForEach(curated) { section in
            if !section.items.isEmpty { appRail(title: section.title, apps: section.items) }
        }

        if !model.newReleases.isEmpty { appRail(title: "New Releases", eyebrow: "Fresh Finds", apps: model.newReleases) }
        if !model.recentlyUpdated.isEmpty { appRail(title: "Recently Updated", apps: model.recentlyUpdated) }
        if model.sections.isEmpty && model.newReleases.isEmpty && model.recentlyUpdated.isEmpty {
            StoreEmptyState(symbol: "sparkles", title: "Nothing featured yet", message: "New picks from your configured store will appear here.")
        }
    }

    private func heroCard(_ app: StoreApp) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RemoteStoreImage(url: app.iconURL, cornerRadius: 28).frame(height: 250)
                    .overlay(alignment: .topTrailing) {
                        Text(app.category.name.uppercased()).font(.caption2.weight(.bold)).tracking(0.7)
                            .padding(.horizontal, 11).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule()).padding(16)
                    }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text("EDITOR’S FEATURE").font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(StorePalette.leaf)
                    Text(app.name).font(.largeTitle.weight(.bold)).tracking(-0.6).foregroundStyle(.white).lineLimit(2)
                    Text(app.developer.name).font(.subheadline).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                }.padding(20)
            }
            HStack {
                Text(app.currentVersion.releaseNotes.isEmpty ? "Explore this week’s pick" : app.currentVersion.releaseNotes)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                NavigationLink(destination: AppDetailsView(repository: modelRepository, appID: app.id)) {
                    Text("GET")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(StorePalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { StoreHaptics.selection() })
                .accessibilityLabel("View \(app.name) and download options")
                NavigationLink(destination: AppDetailsView(repository: modelRepository, appID: app.id)) {
                    Image(systemName: "arrow.up.right").font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(StorePalette.accent, in: Circle())
                }
                .accessibilityLabel("View \(app.name) details")
            }.padding(16)
        }
        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
    }

    private var modelRepository: (any StoreRepository)? { model.repository }

    private func appRail(title: String, eyebrow: String? = nil, apps: [StoreApp]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            StoreSectionHeading(title: title, eyebrow: eyebrow)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(apps) { app in
                        NavigationLink(destination: AppDetailsView(repository: modelRepository, appID: app.id)) {
                            TodayAppTile(app: app)
                        }.buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
}

private struct TodayAppTile: View {
    let app: StoreApp
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteStoreImage(url: app.iconURL, cornerRadius: 23).frame(width: 142, height: 142)
            Text(app.name).font(.headline).lineLimit(1)
            Text(app.developer.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(app.category.name).font(.caption2.weight(.medium)).foregroundStyle(StorePalette.accent).lineLimit(1)
        }
        .padding(10).frame(width: 162, alignment: .leading)
        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
