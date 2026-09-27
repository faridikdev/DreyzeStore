import Foundation

public struct InstalledApplication: Codable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let sourceIdentifier: String
    public let installedAt: Date
}

public struct VerifiedPackage: Sendable {
    public let fileURL: URL
    public let bundleIdentifier: String
    public let version: String
    public let sha256: String
    public let size: Int64

    // Only package-verification code in this app target may construct this
    // value. Phase 4 will define that verifier.
    init(fileURL: URL, bundleIdentifier: String, version: String, sha256: String, size: Int64) {
        self.fileURL = fileURL
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.sha256 = sha256
        self.size = size
    }
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
