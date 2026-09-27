import Foundation

enum PackageLimits {
    static let maximumDownloadBytes: Int64 = 1_073_741_824
    static let maximumArchiveEntries = 100_000
    static let maximumEntryUncompressedBytes: UInt64 = 2_147_483_648
    static let maximumArchiveUncompressedBytes: UInt64 = 8_589_934_592
    static let maximumCompressionRatio: UInt64 = 1_000
    static let maximumInfoPlistBytes = 8 * 1_024 * 1_024
    static let maximumSymlinkTargetBytes = 4 * 1_024
    static let maximumRedirects = 5
    static let transferTimeout: TimeInterval = 30 * 60
}

struct PackageDownloadRelease: Codable, Hashable, Sendable {
    let appID: String
    let name: String
    let developer: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String
    let downloadURL: URL
    let sha256: String
    let size: Int64
    let sourceIdentifier: String
    let sourceName: String
    let iconURL: URL

    init(app: StoreApp) {
        self.init(
            appID: app.id,
            name: app.name,
            developer: app.developer.name,
            bundleIdentifier: app.bundleIdentifier,
            version: app.currentVersion.version,
            build: app.currentVersion.build,
            minimumOSVersion: app.currentVersion.minimumOSVersion,
            downloadURL: app.currentVersion.downloadURL,
            sha256: app.currentVersion.sha256,
            size: app.currentVersion.size,
            sourceIdentifier: app.repositoryIdentifier,
            sourceName: app.repositoryName,
            iconURL: app.iconURL
        )
    }

    init(appID: String, name: String, developer: String, bundleIdentifier: String, version: String, build: String, minimumOSVersion: String, downloadURL: URL, sha256: String, size: Int64, sourceIdentifier: String, sourceName: String, iconURL: URL) {
        self.appID = appID
        self.name = name
        self.developer = developer
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.minimumOSVersion = minimumOSVersion
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.sourceIdentifier = sourceIdentifier
        self.sourceName = sourceName
        self.iconURL = iconURL
    }

    var deduplicationKey: String {
        "\(bundleIdentifier.lowercased())|\(version)|\(build)|\(sha256.lowercased())"
    }
}

struct DownloadProgress: Equatable, Sendable {
    let receivedBytes: Int64
    let expectedBytes: Int64

    var fractionCompleted: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

enum PackageDownloadFailureCode: String, Codable, Sendable {
    case insecureURL
    case duplicateDownload
    case network
    case timeout
    case http
    case redirectLimit
    case insufficientStorage
    case sizeLimit
    case sizeMismatch
    case checksumMismatch
    case invalidArchive
    case unsafeArchive
    case invalidMetadata
    case cancelled
    case unknown
}

struct PackageDownloadFailure: Error, Equatable, Sendable {
    let code: PackageDownloadFailureCode
    let httpStatus: Int?

    init(_ code: PackageDownloadFailureCode, httpStatus: Int? = nil) {
        self.code = code
        self.httpStatus = httpStatus
    }

    var title: String {
        switch code {
        case .checksumMismatch: "Package Verification Failed"
        case .invalidArchive, .unsafeArchive, .invalidMetadata, .sizeMismatch: "Package Rejected"
        case .insufficientStorage: "Not Enough Storage"
        case .cancelled: "Download Cancelled"
        default: "Couldn’t Download App"
        }
    }

    var userMessage: String {
        switch code {
        case .insecureURL: "This repository provided an unsupported download address."
        case .duplicateDownload: "This version is already downloading."
        case .network: "Check your internet connection and try again."
        case .timeout: "The download took too long. Check your connection and retry."
        case .http: "The download server returned an error. Please try again later."
        case .redirectLimit: "The download address redirected too many times. Please contact the repository owner."
        case .insufficientStorage: "Free up storage on your iPhone and try again."
        case .sizeLimit: "The package is larger than the allowed download limit."
        case .sizeMismatch: "The downloaded package size does not match the published metadata."
        case .checksumMismatch: "The downloaded file does not match the checksum published by the repository."
        case .invalidArchive: "The downloaded file is not a valid app package."
        case .unsafeArchive: "The package contains unsafe archive entries and was rejected."
        case .invalidMetadata: "The app information inside the package does not match the store listing."
        case .cancelled: "The download was cancelled."
        case .unknown: "Something went wrong. Please try again."
        }
    }

    var technicalDetails: String {
        if code == .http, let httpStatus { return "HTTP status \(httpStatus)." }
        return code.rawValue
    }
}

enum PackageDownloadState: Equatable, Sendable {
    case idle
    case preparing
    case downloading(DownloadProgress)
    case verifying
    case inspecting
    case ready(VerifiedPackage)
    case failed(PackageDownloadFailure)
    case cancelled

    var isActive: Bool {
        switch self {
        case .preparing, .downloading, .verifying, .inspecting: true
        default: false
        }
    }
}

struct StoredVerifiedPackage: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let appID: String
    let name: String
    let developer: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String
    let sourceIdentifier: String
    let sourceName: String
    let iconURL: URL
    let size: Int64
    let sha256: String
    let verifiedAt: Date
}

struct PackageStorageUsage: Equatable, Sendable {
    let downloadedPackages: Int64
    let temporaryFiles: Int64
    let cache: Int64

    var total: Int64 { downloadedPackages + temporaryFiles + cache }
}

struct PackageDownloadIntent: Codable, Sendable {
    let id: UUID
    let release: PackageDownloadRelease
    let createdAt: Date
    var redirectCount: Int = 0
}

struct PackageTransferOutcome: Codable, Sendable {
    enum Result: String, Codable, Sendable { case completed, failed }
    let result: Result
    let finalURL: URL?
    let statusCode: Int?
    let receivedBytes: Int64?
    let failureCode: PackageDownloadFailureCode?
}

struct PackageTransferResponse: Sendable {
    let fileURL: URL
    let finalURL: URL
    let statusCode: Int
    let receivedBytes: Int64
}
