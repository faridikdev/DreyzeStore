import Foundation

public enum PackageVerificationError: Error, Equatable, Sendable {
    case checksumMismatch
    case invalidArchive
    case unsafeArchive
    case metadataMismatch
    case declaredSizeMismatch
    case malformedMetadata
    case missingPayload
    case missingApplicationBundle
    case missingInfoPlist
    case missingExecutable
}
