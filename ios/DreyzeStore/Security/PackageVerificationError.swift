import Foundation

public enum PackageVerificationError: Error, Equatable, Sendable {
    case checksumMismatch
    case invalidArchive
    case unsafeArchive
    case metadataMismatch
    case declaredSizeMismatch
}

// TODO(Phase 4): implement SHA-256 and IPA archive validation. No package is
// treated as verified by the foundation client.
