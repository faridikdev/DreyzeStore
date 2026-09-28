import Combine
import Foundation

public enum InstalledInventoryState {
    case idle
    case loading
    case live(InstalledInventorySnapshot)
    case cached(InstalledInventorySnapshot)
    case unavailable(String)

    public var isCached: Bool {
        if case .cached = self { return true }
        return false
    }
}

@MainActor
public final class InstalledInventoryService: ObservableObject {
    public static let shared = InstalledInventoryService(provider: WindowsCompanionInstallationBackend())

    @Published public private(set) var state: InstalledInventoryState = .idle

    private let provider: any InstalledAppInventoryProviding
    private let defaults: UserDefaults
    private let cacheKey = "dreyze.inventory.companion-snapshot.v1"
    private let cacheLifetime: TimeInterval = 30 * 24 * 60 * 60
    private var activeSync: Task<InstalledInventorySnapshot, Error>?

    public init(provider: any InstalledAppInventoryProviding, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
    }

    @discardableResult
    public func synchronize() async -> InstalledInventorySnapshot? {
        guard let expectedDeviceIdentifier = provider.expectedDeviceIdentifier else {
            state = .unavailable("Pair DreyzeStore with a trusted iPhone through Windows Companion to read installed apps.")
            return nil
        }
        state = .loading
        let task: Task<InstalledInventorySnapshot, Error>
        if let activeSync {
            task = activeSync
        } else {
            let provider = self.provider
            task = Task { try await provider.fetchInstalledInventory() }
            activeSync = task
        }
        do {
            let snapshot = try await task.value
            activeSync = nil
            guard snapshot.deviceIdentifier == expectedDeviceIdentifier else {
                state = cachedState(for: expectedDeviceIdentifier)
                return currentSnapshot
            }
            let live = InstalledInventorySnapshot(
                records: snapshot.records,
                lastChecked: snapshot.lastChecked,
                deviceIdentifier: snapshot.deviceIdentifier,
                isLive: true
            )
            if let data = try? JSONEncoder().encode(live) { defaults.set(data, forKey: cacheKey) }
            state = .live(live)
            return live
        } catch is CancellationError {
            activeSync = nil
            state = cachedState(for: expectedDeviceIdentifier)
            return currentSnapshot
        } catch {
            activeSync = nil
            state = cachedState(for: expectedDeviceIdentifier)
            if case .cached = state { return currentSnapshot }
            state = .unavailable("Windows Companion is unavailable. Connect the paired computer and refresh to read installed apps.")
            return nil
        }
    }

    public var currentSnapshot: InstalledInventorySnapshot? {
        switch state {
        case .live(let value), .cached(let value): value
        default: nil
        }
    }

    public var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    private func cachedState(for expectedDeviceIdentifier: String) -> InstalledInventoryState {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(InstalledInventorySnapshot.self, from: data),
              cached.deviceIdentifier == expectedDeviceIdentifier,
              Date().timeIntervalSince(cached.lastChecked) <= cacheLifetime else {
            return .unavailable("Windows Companion is unavailable and no inventory snapshot exists for this paired iPhone.")
        }
        return .cached(InstalledInventorySnapshot(
            records: cached.records,
            lastChecked: cached.lastChecked,
            deviceIdentifier: cached.deviceIdentifier,
            isLive: false
        ))
    }
}
