use thiserror::Error;

#[derive(Debug, Error)]
pub enum CompanionError {
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("pairing is required")]
    PairingRequired,
    #[error("pairing code is invalid or expired")]
    InvalidPairingCode,
    #[error("request authentication failed")]
    AuthenticationFailed,
    #[error("request was replayed or expired")]
    ReplayRejected,
    #[error("unsafe package: {0}")]
    InvalidPackage(String),
    #[error("package metadata did not match the verified release")]
    MetadataMismatch,
    #[error("package checksum mismatch")]
    ChecksumMismatch,
    #[error("signing configuration is required")]
    SigningRequired,
    #[error("connected iPhone is required")]
    DeviceUnavailable,
    #[error("external device service is unavailable: {0}")]
    DeviceServiceUnavailable(String),
    #[error("operation failed: {0}")]
    Operation(String),
    #[error("secure storage failed: {0}")]
    SecureStorage(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, CompanionError>;
