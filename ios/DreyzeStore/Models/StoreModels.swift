import Foundation

public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case utilities = "Utilities"
    case developerTools = "Developer Tools"
    case games = "Games"
    case emulators = "Emulators"
    case media = "Media"
    case productivity = "Productivity"
    case social = "Social"
    case customization = "Customization"
    case other = "Other"
}

public struct Developer: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let websiteURL: URL?
}

public struct Category: Codable, Identifiable, Sendable {
    public let id: String
    public let name: AppCategory
    public let appCount: Int?
}

public struct AppScreenshot: Codable, Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let width: Int
    public let height: Int
    public let alt: String
}

public struct AppVersion: Codable, Identifiable, Sendable {
    public var id: String { "\(version)+\(build)" }
    public let version: String
    public let build: String
    public let versionDate: Date
    public let minimumOSVersion: String
    public let downloadURL: URL
    public let sha256: String
    public let size: Int64
    public let releaseNotes: String
    public let channel: String
}

public struct StoreApp: Codable, Identifiable, Sendable {
    public let id: String
    public let bundleIdentifier: String
    public let name: String
    public let developer: Developer
    public let category: Category
    public let description: String
    public let iconURL: URL
    public let screenshots: [AppScreenshot]
    public let currentVersion: AppVersion
    public let repositoryIdentifier: String
    public let repositoryName: String
}
