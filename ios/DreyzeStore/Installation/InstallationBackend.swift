import Foundation

public struct InstalledApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let build: String?
    public let sourceIdentifier: String
    public let installedAt: Date?

    public init(bundleIdentifier: String, version: String, build: String? = nil, sourceIdentifier: String, installedAt: Date? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.sourceIdentifier = sourceIdentifier
        self.installedAt = installedAt
    }
}

public enum BackendAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
    case requiresConfiguration(reason: String)
    case unsupported(reason: String)
}

public struct InstallationCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let confirmedInstall = Self(rawValue: 1 << 0)
    public static let externalHandoff = Self(rawValue: 1 << 1)
    public static let installedState = Self(rawValue: 1 << 2)
    public static let inventory = Self(rawValue: 1 << 3)
    public static let uninstall = Self(rawValue: 1 << 4)
}

public struct InstallationBackendOption: Equatable, Sendable, Identifiable {
    public let identifier: String
    public let displayName: String
    public let availability: BackendAvailability
    public let capabilities: InstallationCapabilities

    public var id: String { identifier }
}

public enum InstallationFailureCode: String, Codable, Equatable, Sendable {
    case backendUnavailable
    case unsupportedOS
    case helperUnavailable
    case signingRequired
    case packageRejected
    case installationFailed
    case permissionDenied
    case userCancelled
    case installationUnconfirmed
}

public struct InstallationFailure: Equatable, Sendable {
    public let code: InstallationFailureCode
    public let title: String
    public let userMessage: String
    public let technicalDetails: String

    public init(code: InstallationFailureCode, title: String, userMessage: String, technicalDetails: String) {
        self.code = code
        self.title = title
        self.userMessage = userMessage
        self.technicalDetails = technicalDetails
    }

    static func packageRejected(_ details: String) -> Self {
        Self(code: .packageRejected, title: "Package Verification Failed", userMessage: "The verified package changed or is no longer available. Download it again before continuing.", technicalDetails: details)
    }

    static func unavailable(_ reason: String) -> Self {
        Self(code: .backendUnavailable, title: "Installation Method Unavailable", userMessage: reason, technicalDetails: reason)
    }

    static func unsupported(_ reason: String) -> Self {
        Self(code: .unsupportedOS, title: "Unsupported Installation Method", userMessage: reason, technicalDetails: reason)
    }

    static func configurationRequired(_ reason: String) -> Self {
        Self(code: .signingRequired, title: "Setup Required", userMessage: reason, technicalDetails: reason)
    }
}

public struct InstallationHandoffReceipt: Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let method: String
    public let destination: String?
    public let handedOffAt: Date
}

public enum InstallationDirective: Sendable {
    case installed(InstalledApplication)
    case handoffRequested
    case cancelled
    case failed(InstallationFailure)
    case unsupported(InstallationFailure)
}

public enum InstallationResult: Equatable, Sendable {
    case installed(InstalledApplication)
    case handedOff(InstallationHandoffReceipt)
    case cancelled
    case failed(InstallationFailure)
    case unsupported(InstallationFailure)
}

public enum UninstallationResult: Equatable, Sendable {
    case uninstalled
    case cancelled
    case failed(InstallationFailure)
    case unsupported(reason: String)
}

public enum InstalledState: Equatable, Sendable {
    case installed(InstalledApplication)
    case notInstalled
    case unavailable(reason: String)
    case unsupported(reason: String)
}

public enum InstallationState: Equatable, Sendable {
    case ready
    case preparingInstallation
    case connectingToCompanion
    case transferringPackage
    case verifyingOnCompanion
    case signing
    case provisioning
    case installing
    case awaitingHandoff
    case handedOff(InstallationHandoffReceipt)
    case installed(InstalledApplication)
    case failed(InstallationFailure)
    case cancelled
    case unsupported(InstallationFailure)

    public var isActive: Bool {
        switch self {
        case .preparingInstallation, .connectingToCompanion, .transferringPackage,
             .verifyingOnCompanion, .signing, .provisioning, .installing, .awaitingHandoff: true
        default: false
        }
    }
}

/// Every installation path receives a package that has already passed the
/// checksum, IPA structure, and server metadata checks in PackageValidator.
public protocol InstallationBackend: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var availability: BackendAvailability { get }
    var capabilities: InstallationCapabilities { get }

    func install(package: VerifiedPackage) async -> InstallationDirective
    func install(package: VerifiedPackage, onProgress: @escaping @Sendable (InstallationProgress) async -> Void) async -> InstallationDirective
    func refreshAvailability() async
    func cancelInstall() async
    func uninstall(bundleIdentifier: String) async -> UninstallationResult
    func queryInstalledState(bundleIdentifier: String) async -> InstalledState
}

public enum InstallationProgress: Sendable {
    case connectingToCompanion
    case transferringPackage
    case verifyingOnCompanion
    case signing
    case provisioning
    case installing
}

public extension InstallationBackend {
    func install(package: VerifiedPackage, onProgress: @escaping @Sendable (InstallationProgress) async -> Void) async -> InstallationDirective {
        await install(package: package)
    }

    func refreshAvailability() async { }
    func cancelInstall() async { }
}
