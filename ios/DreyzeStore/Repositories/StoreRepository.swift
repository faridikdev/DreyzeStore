import Foundation

public protocol StoreRepository: Sendable {
    func apps(page: Int, limit: Int, category: String?, sort: CatalogSort) async throws -> StoreLoad<AppsPage>
    func categories() async throws -> StoreLoad<[StoreCategory]>
    func featured() async throws -> StoreLoad<[FeaturedSection]>
    func search(_ term: String, page: Int, limit: Int) async throws -> StoreLoad<AppsPage>
    func app(id: String) async throws -> StoreLoad<StoreApp>
    func versions(appID: String) async throws -> StoreLoad<[AppVersion]>
    func updates(for installed: [InstalledVersion]) async throws -> [UpdateAvailable]
    func lookupApps(bundleIdentifiers: [String], channel: AppUpdateChannel) async throws -> [StoreApp]
    func repositoryManifest() async throws -> StoreLoad<RepositoryManifest>
}
