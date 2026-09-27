import Foundation

public struct ExternalInstallerBackend: InstallationBackend {
    public let identifier = "external-handoff"
    public let displayName = "External App Handoff"
    public let availability: BackendAvailability = .available
    public let capabilities: InstallationCapabilities = [.externalHandoff]

    public init() {}

    public func install(package: VerifiedPackage) async -> InstallationDirective {
        guard package.localURL.isFileURL, package.localURL.pathExtension.lowercased() == "ipa" else {
            return .failed(.packageRejected("The verified package is not a managed local IPA file."))
        }
        return .handoffRequested
    }

    public func uninstall(bundleIdentifier: String) async -> UninstallationResult {
        .unsupported(reason: "The system share sheet cannot uninstall applications.")
    }

    public func queryInstalledState(bundleIdentifier: String) async -> InstalledState {
        .unsupported(reason: "A share handoff does not expose installed-app state.")
    }
}

public struct TrollStoreBackend: InstallationBackend {
    public let identifier = "trollstore"
    public let displayName = "TrollStore"
    public let availability: BackendAvailability = .unsupported(
        reason: "TrollStore’s documented URL handoff cannot access DreyzeStore’s app-private package file. The apple-magnifier scheme also cannot verify TrollStore is installed."
    )
    public let capabilities: InstallationCapabilities = []

    public init() {}

    public func install(package: VerifiedPackage) async -> InstallationDirective {
        .unsupported(.unsupported(availabilityReason))
    }

    public func uninstall(bundleIdentifier: String) async -> UninstallationResult {
        .unsupported(reason: "TrollStore does not expose a supported uninstall API to this sandboxed client.")
    }

    public func queryInstalledState(bundleIdentifier: String) async -> InstalledState {
        .unsupported(reason: "DreyzeStore cannot query TrollStore’s private installed-app inventory through a supported public API.")
    }

    private var availabilityReason: String {
        if case .unsupported(let reason) = availability { return reason }
        return "TrollStore handoff is unavailable in this build."
    }
}

public struct TrollStoreLiteBackend: InstallationBackend {
    public let identifier = "trollstore-lite"
    public let displayName = "TrollStore Lite"
    public let availability: BackendAvailability = .unsupported(
        reason: "TrollStore Lite requires its jailbreak-specific privileged helper and private-framework environment; DreyzeStore does not include or invoke that helper."
    )
    public let capabilities: InstallationCapabilities = []

    public init() {}

    public func install(package: VerifiedPackage) async -> InstallationDirective {
        .unsupported(.unsupported(availabilityReason))
    }

    public func uninstall(bundleIdentifier: String) async -> UninstallationResult {
        .unsupported(reason: "TrollStore Lite uninstall requires its privileged helper, which is not part of DreyzeStore.")
    }

    public func queryInstalledState(bundleIdentifier: String) async -> InstalledState {
        .unsupported(reason: "TrollStore Lite inventory requires its jailbreak helper and is not available to DreyzeStore.")
    }

    private var availabilityReason: String {
        if case .unsupported(let reason) = availability { return reason }
        return "TrollStore Lite is unavailable in this build."
    }
}

public struct DeveloperSigningBackend: InstallationBackend {
    public let identifier = "developer-signing"
    public let displayName = "Developer Signing"
    public let availability: BackendAvailability = .requiresConfiguration(
        reason: "Configure a local signer, developer certificate, provisioning profile, and supported device-install workflow. DreyzeStore does not collect or upload Apple credentials."
    )
    public let capabilities: InstallationCapabilities = []

    public init() {}

    public func install(package: VerifiedPackage) async -> InstallationDirective {
        .unsupported(.configurationRequired(configurationReason))
    }

    public func uninstall(bundleIdentifier: String) async -> UninstallationResult {
        .unsupported(reason: "Developer signing is not configured and cannot uninstall applications.")
    }

    public func queryInstalledState(bundleIdentifier: String) async -> InstalledState {
        .unavailable(reason: "Developer signing is not configured, so DreyzeStore has no installed-app inventory.")
    }

    private var configurationReason: String {
        if case .requiresConfiguration(let reason) = availability { return reason }
        return "Developer signing is not configured."
    }
}

public enum InstallationBackendCatalog {
    public static let standard: [any InstallationBackend] = [
        ExternalInstallerBackend(),
        TrollStoreBackend(),
        TrollStoreLiteBackend(),
        DeveloperSigningBackend()
    ]
}
