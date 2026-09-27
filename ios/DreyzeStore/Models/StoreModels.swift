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

public struct UpdateAppReference: Codable, Hashable, Sendable, Identifiable {
    public var id: String { bundleIdentifier }
    public let idFromAPI: String?
    public let bundleIdentifier: String
    public let name: String
    enum CodingKeys: String, CodingKey { case idFromAPI = "id", bundleIdentifier, name }
}

public struct UpdateAvailable: Codable, Hashable, Sendable, Identifiable {
    public var id: String { app.bundleIdentifier }
    public let app: UpdateAppReference
    public let installedVersion: String
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
    public init(bundleIdentifier: String, installedVersion: String) {
        self.bundleIdentifier = bundleIdentifier
        self.installedVersion = installedVersion
    }
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
