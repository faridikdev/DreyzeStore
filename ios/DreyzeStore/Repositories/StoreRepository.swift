import Foundation

public protocol StoreRepository: Sendable {
    func featuredApps() async throws -> [StoreApp]
    func app(withIdentifier identifier: String) async throws -> StoreApp
}

// TODO(Phase 3): implement against the versioned API and validated repository
// manifests before any store screen attempts to load catalog content.
