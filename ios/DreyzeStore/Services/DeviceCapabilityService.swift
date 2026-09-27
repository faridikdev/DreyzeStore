import Foundation

public struct InstallationCapability: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case available
        case requiresUserAction
        case unavailable
        case unknown
    }

    public var id: String { identifier }
    public let identifier: String
    public let displayName: String
    public let state: State
    public let explanation: String
}

public struct DeviceCapabilities: Codable, Sendable {
    public let operatingSystemVersion: String
    public let installationBackends: [InstallationCapability]
}

public struct DeviceCapabilityService: Sendable {
    public init() {}

    public func currentCapabilities() -> DeviceCapabilities {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        // No installation adapters are shipped in this foundation build. An
        // empty list means no backend has been detected or declared available.
        return DeviceCapabilities(operatingSystemVersion: systemVersion, installationBackends: [])
    }
}
