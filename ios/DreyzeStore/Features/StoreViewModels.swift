import Foundation
import Combine

enum StoreScreenState: Equatable {
    case idle, loading, loaded, refreshing, offlineCached, error(String)
}

enum StoreFailure {
    static func message(for error: Error) -> String {
        if let error = error as? StoreError { return error.userMessage }
        return "Something went wrong. Please try again."
    }
}

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var state: StoreScreenState = .idle
    @Published private(set) var sections: [FeaturedSection] = []
    @Published private(set) var newReleases: [StoreApp] = []
    @Published private(set) var recentlyUpdated: [StoreApp] = []
    @Published private(set) var receivedAt: Date?
    let repository: (any StoreRepository)?
    private var isLoading = false

    init(repository: (any StoreRepository)?) { self.repository = repository }

    func load(refresh: Bool = false) async {
        guard !isLoading else { return }
        guard let repository else { state = .error(StoreError.configurationUnavailable.userMessage); return }
        isLoading = true
        defer { isLoading = false }
        let hasContent = !sections.isEmpty || !newReleases.isEmpty || !recentlyUpdated.isEmpty
        state = hasContent ? (refresh ? .refreshing : state) : .loading
        async let featured = try? await repository.featured()
        async let newest = try? await repository.apps(page: 1, limit: 12, category: nil, sort: .newest)
        async let updated = try? await repository.apps(page: 1, limit: 12, category: nil, sort: .updated)
        let (featuredResult, newestResult, updatedResult) = await (featured, newest, updated)
        guard !Task.isCancelled else { return }
        if let featuredResult { sections = featuredResult.value }
        if let newestResult { newReleases = newestResult.value.data }
        if let updatedResult { recentlyUpdated = updatedResult.value.data }
        let successes = [featuredResult?.receivedAt, newestResult?.receivedAt, updatedResult?.receivedAt].compactMap { $0 }
        receivedAt = successes.min()
        let hasCache = featuredResult?.source == .cache || newestResult?.source == .cache || updatedResult?.source == .cache
        if successes.isEmpty { state = hasContent ? .offlineCached : .error(StoreError.networkUnavailable.userMessage) }
        else { state = hasCache ? .offlineCached : .loaded }
    }
}

@MainActor
final class AppsViewModel: ObservableObject {
    @Published private(set) var state: StoreScreenState = .idle
    @Published private(set) var apps: [StoreApp] = []
    @Published private(set) var categories: [StoreCategory] = []
    @Published var selectedCategory: String?
    @Published var sort: CatalogSort = .name
    @Published private(set) var hasMore = false
    @Published private(set) var pageError: String?
    let repository: (any StoreRepository)?
    private let pageSize = 24
    private var page = 1
    private var isLoadingPage = false
    private var pendingReload = false

    init(repository: (any StoreRepository)?) { self.repository = repository }

    func load(refresh: Bool = false) async {
        guard let repository else { state = .error(StoreError.configurationUnavailable.userMessage); return }
        guard !isLoadingPage else { if refresh { pendingReload = true }; return }
        isLoadingPage = true
        defer {
            isLoadingPage = false
            if pendingReload {
                pendingReload = false
                Task { await self.load(refresh: true) }
            }
        }
        let hadItems = !apps.isEmpty
        let requestedCategory = selectedCategory
        let requestedSort = sort
        state = hadItems ? (refresh ? .refreshing : state) : .loading
        if categories.isEmpty, let loaded = try? await repository.categories() { categories = loaded.value }
        if refresh { page = 1 }
        let requestedPage = page
        do {
            let result = try await repository.apps(page: requestedPage, limit: pageSize, category: requestedCategory, sort: requestedSort)
            guard requestedCategory == selectedCategory, requestedSort == sort else { pendingReload = true; return }
            if requestedPage == 1 { apps = result.value.data } else { apps.append(contentsOf: result.value.data) }
            hasMore = result.value.meta?.hasMore ?? false
            pageError = nil
            state = result.source == .cache ? .offlineCached : (apps.isEmpty ? .loaded : .loaded)
        } catch is CancellationError {
        } catch {
            guard requestedCategory == selectedCategory, requestedSort == sort else { pendingReload = true; return }
            pageError = StoreFailure.message(for: error)
            state = hadItems ? .offlineCached : .error(StoreFailure.message(for: error))
        }
    }

    func selectCategory(_ category: String?) async {
        guard selectedCategory != category else { return }
        selectedCategory = category
        page = 1
        apps = []
        pageError = nil
        state = .loading
        hasMore = false
        await load(refresh: true)
    }

    func selectSort(_ value: CatalogSort) async {
        guard sort != value else { return }
        sort = value
        page = 1
        apps = []
        pageError = nil
        state = .loading
        await load(refresh: true)
    }

    func loadNextPageIfNeeded(current app: StoreApp) async {
        guard hasMore, !isLoadingPage, apps.last?.id == app.id else { return }
        page += 1
        await load()
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var state: StoreScreenState = .idle
    @Published private(set) var apps: [StoreApp] = []
    @Published private(set) var hasSearched = false
    @Published private(set) var recentSearches: [String]
    @Published private(set) var hasMore = false
    @Published var text = "" { didSet { scheduleSearch(text) } }
    let repository: (any StoreRepository)?
    private let defaults: UserDefaults
    private let debounceNanoseconds: UInt64
    private var searchTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var isLoadingRequest = false
    private var activeRequestID: UUID?
    private var page = 1

    init(repository: (any StoreRepository)?, defaults: UserDefaults = .standard, debounceNanoseconds: UInt64 = 350_000_000) {
        self.repository = repository
        self.defaults = defaults
        self.debounceNanoseconds = debounceNanoseconds
        self.recentSearches = defaults.stringArray(forKey: "dreyze.recentSearches") ?? []
    }

    func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        requestTask?.cancel()
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            apps = []
            hasSearched = false
            state = .idle
            return
        }
        hasSearched = true
        state = .loading
        searchTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return }
            guard !Task.isCancelled else { return }
            await performSearch(term, page: 1, append: false)
        }
    }

    func submit(_ term: String? = nil) async {
        let value = (term ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchTask?.cancel()
        await performSearch(value, page: 1, append: false)
    }

    func searchNextPage() async {
        guard hasMore, !isLoadingRequest, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await performSearch(text.trimmingCharacters(in: .whitespacesAndNewlines), page: page + 1, append: true)
    }

    func clearHistory() {
        recentSearches = []
        defaults.removeObject(forKey: "dreyze.recentSearches")
    }

    func cancel() { searchTask?.cancel(); requestTask?.cancel() }

    private func performSearch(_ term: String, page nextPage: Int, append: Bool) async {
        if append && isLoadingRequest { return }
        guard let repository else { state = .error(StoreError.configurationUnavailable.userMessage); return }
        requestTask?.cancel()
        isLoadingRequest = true
        let requestID = UUID()
        activeRequestID = requestID
        defer {
            if activeRequestID == requestID {
                activeRequestID = nil
                isLoadingRequest = false
            }
        }
        page = nextPage
        state = .loading
        hasSearched = true
        let current = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.search(term, page: nextPage, limit: 24)
                guard !Task.isCancelled, text.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                if append { apps.append(contentsOf: result.value.data) } else { apps = result.value.data }
                hasMore = result.value.meta?.hasMore ?? false
                state = result.source == .cache ? .offlineCached : .loaded
                addRecent(term)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                state = .error(StoreFailure.message(for: error))
                if !append { apps = [] }
            }
        }
        requestTask = current
        await current.value
    }

    private func addRecent(_ term: String) {
        recentSearches.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        recentSearches.insert(term, at: 0)
        recentSearches = Array(recentSearches.prefix(10))
        defaults.set(recentSearches, forKey: "dreyze.recentSearches")
    }
}

@MainActor
final class AppDetailsViewModel: ObservableObject {
    @Published private(set) var state: StoreScreenState = .idle
    @Published private(set) var app: StoreApp?
    @Published private(set) var versions: [AppVersion] = []
    private let repository: (any StoreRepository)?
    private let appID: String

    init(repository: (any StoreRepository)?, appID: String) { self.repository = repository; self.appID = appID }

    func load(refresh: Bool = false) async {
        guard let repository else { state = .error(StoreError.configurationUnavailable.userMessage); return }
        guard app == nil || refresh else { return }
        state = app == nil ? .loading : .refreshing
        async let history = try? await repository.versions(appID: appID)
        do {
            let appResult = try await repository.app(id: appID)
            let versionsResult = await history
            guard !Task.isCancelled else { return }
            app = appResult.value
            versions = versionsResult?.value ?? []
            state = appResult.source == .cache || versionsResult?.source == .cache ? .offlineCached : .loaded
        } catch is CancellationError {
        } catch {
            state = app == nil ? .error(StoreFailure.message(for: error)) : .offlineCached
        }
    }
}
