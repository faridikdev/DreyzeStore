import Foundation

public protocol CatalogSnapshotStore: Sendable {
    func loadLastSuccessfulCatalog() async throws -> Data?
    func saveSuccessfulCatalog(_ data: Data, receivedAt: Date) async throws
}

// TODO(Phase 3): add a bounded on-disk implementation with atomic writes and
// age-based cleanup; this interface intentionally stores no sample catalog.
