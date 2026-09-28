import Foundation

public struct Developer: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let websiteURL: URL?
}

public struct StoreCategory: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let appCount: Int?
}

public struct AppScreenshot: Codable, Hashable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let width: Int
    public let height: Int
    public let alt: String
}

public struct AppVersion: Codable, Hashable, Sendable, Identifiable {
    public let id: String?
    public let version: String
    public let build: String
    public let versionDate: Date?
    public let minimumOSVersion: String
    public let downloadURL: URL
    public let sha256: String
    public let size: Int64
    public let releaseNotes: String
    public let channel: String
}

public struct StoreApp: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let bundleIdentifier: String
    public let name: String
    public let shortDescription: String?
    public let developer: Developer
    public let category: StoreCategory
    public let iconURL: URL
    public let currentVersion: AppVersion
    public let repositoryIdentifier: String
    public let repositoryName: String
    public let description: String?
    public let screenshots: [AppScreenshot]?
}

public struct AppsPage: Codable, Sendable {
    public let data: [StoreApp]
    public let meta: PageMetadata?
}

public struct PageMetadata: Codable, Sendable {
    public let requestId: String?
    public let page: Int?
    public let pageSize: Int?
    public let hasMore: Bool?
    public let nextCursor: String?
}

public struct FeaturedSection: Codable, Hashable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let items: [StoreApp]
}

public struct UpdateAvailable: Codable, Hashable, Sendable, Identifiable {
    public var id: String { app.bundleIdentifier }
    public let app: StoreApp
    public let installedVersion: String
    public let installedBuild: String?
    public let channel: String
    public let latestVersion: AppVersion
}

public struct RepositoryManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let identifier: String
    public let description: String
    public let icon: URL
    public let generatedAt: Date
    public let apps: [RepositoryApp]
}

public struct RepositoryApp: Codable, Sendable {
    public let bundleIdentifier: String
    public let name: String
    public let developer: String
    public let category: String
    public let description: String
    public let icon: URL
    public let screenshots: [AppScreenshot]
    public let versions: [AppVersion]
}

public struct InstalledVersion: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let installedVersion: String
    public let installedBuild: String?
    public let channel: String

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case installedVersion = "version"
        case installedBuild = "build"
        case channel
    }

    public init(bundleIdentifier: String, installedVersion: String, installedBuild: String? = nil, channel: String = "stable") {
        self.bundleIdentifier = bundleIdentifier
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        self.channel = channel
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(installedVersion, forKey: .installedVersion)
        if let installedBuild { try container.encode(installedBuild, forKey: .installedBuild) }
        else { try container.encodeNil(forKey: .installedBuild) }
        try container.encode(channel, forKey: .channel)
    }
}

public enum InstalledAppSource: String, Codable, Hashable, Sendable {
    case companionConfirmed
    case localRecordOnly
    case unknown
}

public struct InstalledAppRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(deviceIdentifier):\(installedBundleIdentifier)" }
    public let originalBundleIdentifier: String?
    public let installedBundleIdentifier: String
    public let version: String?
    public let build: String?
    public let releaseSHA256: String?
    public let teamIdentifier: String?
    public let provisionExpiration: Date?
    public let installedAt: Date?
    public let deviceIdentifier: String
    public let source: InstalledAppSource

    public var canonicalBundleIdentifier: String { originalBundleIdentifier ?? installedBundleIdentifier }
    public var isCompanionConfirmed: Bool { source == .companionConfirmed }
}

public struct InstalledInventorySnapshot: Codable, Sendable {
    public let records: [InstalledAppRecord]
    public let lastChecked: Date
    public let deviceIdentifier: String
    public let isLive: Bool
}

public enum AppUpdateChannel: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case stable
    case beta
    public var id: String { rawValue }
}

public enum UpdateState: Equatable, Sendable {
    case upToDate
    case updateAvailable
    case downloading
    case verifying
    case readyToInstall
    case connectingToCompanion
    case signing
    case installing
    case confirming
    case updated
    case failed(String)
    case incompatible(String)
    case signingExpired
    case companionUnavailable
}

public enum UpdateHistoryResult: String, Codable, Hashable, Sendable {
    case updated
    case refreshed
    case failed
}

public struct UpdateHistoryRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let appName: String
    public let bundleIdentifier: String
    public let oldVersion: String
    public let newVersion: String
    public let date: Date
    public let result: UpdateHistoryResult
    public let message: String?
}

struct UpToDateApp: Identifiable {
    let record: InstalledAppRecord
    let app: StoreApp
    var id: String { record.id }
}

public struct StoreLoad<Value: Sendable>: Sendable {
    public enum Source: Sendable, Equatable { case network, cache }
    public let value: Value
    public let source: Source
    public let receivedAt: Date
}

public enum CatalogSort: String, CaseIterable, Identifiable, Sendable {
    case name, updated, newest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .name: "Name"
        case .updated: "Recently Updated"
        case .newest: "New Releases"
        }
    }
}
