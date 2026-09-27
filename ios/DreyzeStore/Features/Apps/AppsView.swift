import SwiftUI

struct AppsView: View {
    @StateObject private var model: AppsViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(repository: (any StoreRepository)?) { _model = StateObject(wrappedValue: AppsViewModel(repository: repository)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                categoryFilters
                if model.state == .offlineCached { OfflineNotice() }
                switch model.state {
                case .idle:
                    skeletons
                case .loading where model.apps.isEmpty:
                    skeletons
                case .error(let message) where model.apps.isEmpty:
                    StoreLoadError(title: "Couldn’t Load Apps", message: message) { Task { await model.load(refresh: true) } }
                default:
                    if model.apps.isEmpty {
                        StoreEmptyState(symbol: "square.grid.2x2", title: "No Apps Here", message: "There are no published apps matching this filter yet.")
                    } else {
                        ForEach(model.apps) { app in
                            AppSummaryCard(app: app, repository: model.repository)
                                .task { await model.loadNextPageIfNeeded(current: app) }
                        }
                        if let pageError = model.pageError {
                            Button { Task { await model.load() } } label: { Label(pageError, systemImage: "arrow.clockwise") }
                                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                        } else if model.hasMore {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 32)
        }
        .background(StorePalette.canvas.ignoresSafeArea())
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("Sort by", selection: Binding(get: { model.sort }, set: { value in StoreHaptics.selection(); Task { await model.selectSort(value) } })) {
                        ForEach(CatalogSort.allCases) { sort in Text(sort.title).tag(sort) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down").accessibilityLabel("Sort apps") }
            }
            ToolbarItem(placement: .navigationBarTrailing) { ProfileButton() }
        }
        .refreshable { await model.load(refresh: true) }
        .task { await model.load() }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: model.apps.count)
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                categoryChip(title: "All", id: nil, count: nil)
                ForEach(model.categories) { category in categoryChip(title: category.name, id: category.id, count: category.appCount) }
            }
        }.scrollIndicators(.hidden)
    }

    private func categoryChip(title: String, id: String?, count: Int?) -> some View {
        let selected = model.selectedCategory == id
        return Button { StoreHaptics.selection(); Task { await model.selectCategory(id) } } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 { Text(count.formatted()).foregroundStyle(selected ? .white.opacity(0.75) : .secondary) }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(selected ? StorePalette.accent : StorePalette.surface, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var skeletons: some View { VStack(spacing: 12) { ForEach(0..<5, id: \.self) { _ in StoreSkeletonCard() } } }
}
