use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageExpectation {
    pub request_id: String,
    pub bundle_identifier: String,
    pub version: String,
    pub build: String,
    pub minimum_os_version: Option<String>,
    pub sha256: String,
    pub size: u64,
    pub app_name: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageMetadata {
    pub bundle_identifier: String,
    pub version: String,
    pub build: String,
    pub minimum_os_version: Option<String>,
    pub app_name: Option<String>,
    pub size: u64,
    pub sha256: String,
}

#[derive(Clone, Debug)]
pub struct ValidatedPackage {
    pub path: PathBuf,
    pub metadata: PackageMetadata,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedPackageInfo {
    pub bundle_identifier: String,
    pub version: String,
    pub build: String,
    pub original_sha256: String,
    pub signed_sha256: String,
    pub signing_identity: String,
    pub team_identifier: Option<String>,
    pub certificate_expires_at: Option<DateTime<Utc>>,
    pub provisioning_expiration: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug)]
pub struct SignedPackage {
    pub path: PathBuf,
    pub info: SignedPackageInfo,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub udid: String,
    pub name: String,
    pub product_type: Option<String>,
    pub product_version: Option<String>,
    pub build_version: Option<String>,
    pub developer_mode: Option<bool>,
    pub trusted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledApp {
    pub bundle_identifier: String,
    pub version: Option<String>,
    pub build: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "state", content = "detail")]
pub enum InstallState {
    Received,
    Verifying,
    Provisioning,
    Signing,
    Installing,
    Confirming,
    Installed {
        app: InstalledApp,
        installed_at: DateTime<Utc>,
        signing: SignedPackageInfo,
    },
    Failed {
        code: String,
        message: String,
    },
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallReceipt {
    pub request_id: String,
    pub state: InstallState,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SigningStatus {
    pub configured: bool,
    pub identity_label: Option<String>,
    pub certificate_expires_at: Option<DateTime<Utc>>,
    pub provisioning_expires_at: Option<DateTime<Utc>>,
    pub team_id: Option<String>,
    pub account_kind: Option<String>,
    pub limitation: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReadinessStatus {
    Pass,
    Fail,
    Unknown,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessCheck {
    pub status: ReadinessStatus,
    pub details: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceReadiness {
    pub run_at: DateTime<Utc>,
    pub apple_mobile_device_service: ReadinessCheck,
    pub usb_connection: ReadinessCheck,
    pub trust: ReadinessCheck,
    pub developer_mode: ReadinessCheck,
    pub pymobiledevice3: ReadinessCheck,
    pub signing_identity: ReadinessCheck,
    pub provisioning: ReadinessCheck,
    pub dreyze_pairing: ReadinessCheck,
}

impl SigningStatus {
    pub fn not_configured() -> Self {
        Self {
            configured: false,
            identity_label: None,
            certificate_expires_at: None,
            provisioning_expires_at: None,
            team_id: None,
            account_kind: None,
            limitation: Some(
                "Import an Apple Development .p12 and a device-matched .mobileprovision file."
                    .into(),
            ),
        }
    }
}
