import Combine
import Foundation

public struct HandedOffPackage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let sourceName: String
    public let iconURL: URL
    public let method: String
    public let destination: String?
    public let handedOffAt: Date
}

@MainActor
public final class InstallationHistoryStore: ObservableObject {
    public static let shared = InstallationHistoryStore(defaults: .standard)

    @Published public private(set) var handedOffPackages: [HandedOffPackage]

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = "dreyzestore.installation.handed-off.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([HandedOffPackage].self, from: data) {
            handedOffPackages = Array(decoded.prefix(100))
        } else {
            handedOffPackages = []
        }
    }

    func record(_ package: VerifiedPackage, storedPackage: StoredVerifiedPackage, receipt: InstallationHandoffReceipt) {
        let record = HandedOffPackage(
            id: UUID(),
            name: storedPackage.name,
            bundleIdentifier: package.bundleIdentifier,
            version: package.version,
            sourceName: package.sourceName,
            iconURL: storedPackage.iconURL,
            method: receipt.method,
            destination: receipt.destination,
            handedOffAt: receipt.handedOffAt
        )
        handedOffPackages.insert(record, at: 0)
        handedOffPackages = Array(handedOffPackages.prefix(100))
        if let data = try? JSONEncoder().encode(handedOffPackages) {
            defaults.set(data, forKey: key)
        }
    }
}
