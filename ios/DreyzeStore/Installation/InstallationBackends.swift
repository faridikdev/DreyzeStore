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
    public let displayName = "TrollStore / Lite Import (Open In)"
    /// The public iOS document-import route is available. The actual recipient
    /// is selected in the system Open In menu and is verified by its bundle ID.
    public let availability: BackendAvailability = .available
    public let capabilities: InstallationCapabilities = [.externalHandoff]

    public init() {}

    public func install(package: VerifiedPackage) async -> InstallationDirective {
        guard package.localURL.isFileURL,
              package.localURL.pathExtension.lowercased() == "ipa",
              FileManager.default.isReadableFile(atPath: package.localURL.path) else {
            return .failed(.packageRejected("The verified package is not an available local IPA file."))
        }
        // The coordinator revalidates the PackageStorage receipt, digest, and
        // IPA metadata immediately before calling this backend. UIKit then
        // hands that file to an IPA document handler; TrollStore owns the
        // installation flow and may show its prompt according to user settings.
        return .handoffRequested
    }

    public func uninstall(bundleIdentifier: String) async -> UninstallationResult {
        .unsupported(reason: "TrollStore does not expose a supported uninstall API to this sandboxed client.")
    }

    public func queryInstalledState(bundleIdentifier: String) async -> InstalledState {
        .unsupported(reason: "The TrollStore document-import callback confirms file handoff only; it does not expose installed-app inventory to DreyzeStore.")
    }
}

enum TrollStoreImportTarget {
    static let ipaContentTypeIdentifier = "com.apple.itunes.ipa"
    static let trollStoreBundleIdentifier = "com.opa334.TrollStore"
    static let trollStoreLiteBundleIdentifier = "com.opa334.TrollStoreLite"

    static func displayName(for bundleIdentifier: String?) -> String? {
        switch bundleIdentifier {
        case trollStoreBundleIdentifier: "TrollStore"
        case trollStoreLiteBundleIdentifier: "TrollStore Lite"
        default: nil
        }
    }
}

public struct TrollStoreLiteBackend: InstallationBackend {
    public let identifier = "trollstore-lite"
    public let displayName = "TrollStore Lite Direct Helper"
    public let availability: BackendAvailability = .unsupported(
        reason: "Direct helper integration requires a jailbreak-specific privileged helper and private frameworks. If TrollStore Lite is installed, it can receive IPA files through the TrollStore Import (Open In) route; DreyzeStore does not call its helper."
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
        TrollStoreBackend(),
        ExternalInstallerBackend(),
        TrollStoreLiteBackend(),
        DeveloperSigningBackend()
    ]
}
