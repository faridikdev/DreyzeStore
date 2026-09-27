import SwiftUI

struct SearchView: View {
    @StateObject private var model: SearchViewModel

    init(repository: (any StoreRepository)?) { _model = StateObject(wrappedValue: SearchViewModel(repository: repository)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.text.isEmpty {
                    recentSearches
                } else if model.state == .offlineCached {
                    OfflineNotice()
                }

                if case let .error(message) = model.state {
                    StoreLoadError(title: "Search Unavailable", message: message) { Task { await model.submit() } }
                } else if model.state == .loading && model.apps.isEmpty && model.hasSearched {
                    ForEach(0..<4, id: \.self) { _ in StoreSkeletonCard() }
                } else if model.hasSearched && model.apps.isEmpty && model.state != .loading {
                    StoreEmptyState(symbol: "magnifyingglass", title: "No Results", message: "Try a different app name, developer, or bundle identifier.")
                } else {
                    if model.state == .loading && !model.apps.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 4) }
                    ForEach(model.apps) { app in
                        AppSummaryCard(app: app, repository: model.repository)
                            .task { if model.apps.last?.id == app.id { await model.searchNextPage() } }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 28)
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() } }
        .searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Apps, developers, bundle IDs")
        .onSubmit(of: .search) { Task { await model.submit() } }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var recentSearches: some View {
        if !model.recentSearches.isEmpty {
            HStack {
                StoreSectionHeading(title: "Recent Searches")
                Spacer()
                Button("Clear") { model.clearHistory() }.font(.subheadline.weight(.medium)).foregroundStyle(StorePalette.accent)
            }
            FlowRecentSearches(items: model.recentSearches) { model.text = $0 }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Find your next favorite").font(.title2.bold()).tracking(-0.4)
                Text("Search apps, developers, and bundle identifiers.").font(.subheadline).foregroundStyle(.secondary)
            }.padding(.top, 16)
        }
    }
}

private struct FlowRecentSearches: View {
    let items: [String]
    let select: (String) -> Void
    var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { select(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text(item).foregroundStyle(.primary).lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
                    }.padding(13).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.buttonStyle(.plain)
            }
        }
    }
}
