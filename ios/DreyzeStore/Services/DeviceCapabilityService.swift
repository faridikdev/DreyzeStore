import Foundation

public struct InstallationCapability: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case available
        case requiresConfiguration
        case unavailable
        case unsupported
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

        let backends = InstallationBackendCatalog.standard.map { backend in
            let state: InstallationCapability.State
            let explanation: String
            switch backend.availability {
            case .available:
                state = .available
                if backend.identifier == TrollStoreBackend().identifier {
                    explanation = "Can hand a verified IPA to TrollStore or TrollStore Lite through Open In when registered. The receiving app owns installation and any confirmation prompt; DreyzeStore cannot confirm the result."
                } else if backend.capabilities.contains(.externalHandoff) {
                    explanation = "Can hand a verified package to the system share sheet; installation is not confirmed."
                } else {
                    explanation = "Available for this device."
                }
            case .unavailable(let reason):
                state = .unavailable
                explanation = reason
            case .requiresConfiguration(let reason):
                state = .requiresConfiguration
                explanation = reason
            case .unsupported(let reason):
                state = .unsupported
                explanation = reason
            }
            return InstallationCapability(identifier: backend.identifier, displayName: backend.displayName, state: state, explanation: explanation)
        }
        return DeviceCapabilities(operatingSystemVersion: systemVersion, installationBackends: backends)
    }
}
