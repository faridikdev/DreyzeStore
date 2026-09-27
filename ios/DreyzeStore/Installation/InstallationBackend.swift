import Foundation

public struct InstalledApplication: Codable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let sourceIdentifier: String
    public let installedAt: Date
}

public enum InstallationOutcome: Sendable {
    case installed(InstalledApplication)
    case externalHandoff(description: String)
}

public protocol InstallationBackend: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    func isAvailable() async -> Bool
    func install(package: VerifiedPackage) async throws -> InstallationOutcome
    func uninstall(bundleIdentifier: String) async throws
}

// No concrete backend is included. A downloaded or verified package is not an
// installation, and this interface provides no success implementation.
