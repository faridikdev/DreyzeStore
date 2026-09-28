import Combine
import Foundation

@MainActor
public final class UpdateHistoryStore: ObservableObject {
    public static let shared = UpdateHistoryStore()

    @Published public private(set) var records: [UpdateHistoryRecord]

    private let defaults: UserDefaults
    private let key = "dreyze.updates.history.v1"
    private let maximumRecords = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([UpdateHistoryRecord].self, from: data) {
            records = decoded.sorted { $0.date > $1.date }
        } else {
            records = []
        }
    }

    public var recentlyUpdated: [UpdateHistoryRecord] {
        records.filter { $0.result == .updated || $0.result == .refreshed }
    }

    public func record(
        appName: String,
        bundleIdentifier: String,
        oldVersion: String,
        newVersion: String,
        result: UpdateHistoryResult,
        message: String? = nil,
        date: Date = Date()
    ) {
        let item = UpdateHistoryRecord(
            id: UUID(),
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            oldVersion: oldVersion,
            newVersion: newVersion,
            date: date,
            result: result,
            message: message
        )
        records = Array(([item] + records).prefix(maximumRecords))
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }
}
