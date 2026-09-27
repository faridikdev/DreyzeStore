use crate::{
    device::pymobiledevice3::DeviceProvider,
    error::{CompanionError, Result},
    models::{InstallState, PackageExpectation, ValidatedPackage},
    package::validator::PackageValidator,
    signing::zsign::SigningProvider,
};
use chrono::Utc;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Instant,
};
use tokio::task;
use tokio_util::sync::CancellationToken;

#[derive(Clone, Default)]
pub struct InstallJobStore {
    states: Arc<Mutex<HashMap<String, InstallState>>>,
    cancellations: Arc<Mutex<HashMap<String, CancellationToken>>>,
    created_at: Arc<Mutex<HashMap<String, Instant>>>,
}

impl InstallJobStore {
    pub fn insert(&self, request_id: String) -> Option<CancellationToken> {
        let cancel = CancellationToken::new();
        let now = Instant::now();
        {
            let mut states = self.states.lock().expect("install store poisoned");
            let mut cancellations = self.cancellations.lock().expect("install store poisoned");
            let mut created_at = self.created_at.lock().expect("install store poisoned");
            let expired: Vec<String> = created_at
                .iter()
                .filter(|(id, created)| {
                    now.duration_since(**created).as_secs() > 30 * 60
                        && !cancellations.contains_key(id.as_str())
                })
                .map(|(id, _)| id.clone())
                .collect();
            for id in expired {
                created_at.remove(&id);
                states.remove(&id);
            }
            if states.len() >= 256 {
                return None;
            }
            created_at.insert(request_id.clone(), now);
            states.insert(request_id.clone(), InstallState::Received);
            cancellations.insert(request_id, cancel.clone());
        }
        Some(cancel)
    }

    pub fn get(&self, request_id: &str) -> Option<InstallState> {
        self.states
            .lock()
            .expect("install store poisoned")
            .get(request_id)
            .cloned()
    }

    pub fn set(&self, request_id: &str, state: InstallState) {
        if let Some(current) = self
            .states
            .lock()
            .expect("install store poisoned")
            .get_mut(request_id)
        {
            *current = state;
        }
    }

    pub fn cancel(&self, request_id: &str) -> bool {
        let cancellations = self.cancellations.lock().expect("install store poisoned");
        if let Some(token) = cancellations.get(request_id) {
            token.cancel();
            true
        } else {
            false
        }
    }

    pub fn finish(&self, request_id: &str) {
        self.cancellations
            .lock()
            .expect("install store poisoned")
            .remove(request_id);
    }
}

pub struct PackageInstallCoordinator {
    devices: Arc<dyn DeviceProvider>,
    signer: Arc<dyn SigningProvider>,
    jobs: InstallJobStore,
}

impl PackageInstallCoordinator {
    pub fn new(
        devices: Arc<dyn DeviceProvider>,
        signer: Arc<dyn SigningProvider>,
        jobs: InstallJobStore,
    ) -> Self {
        Self {
            devices,
            signer,
            jobs,
        }
    }

    pub async fn execute(
        &self,
        file: PathBuf,
        expected: PackageExpectation,
        udid: String,
        cancel: CancellationToken,
    ) -> Result<()> {
        let request_id = expected.request_id.clone();
        let result = self
            .execute_inner(&file, &expected, &udid, &request_id, &cancel)
            .await;
        match result {
            Ok(()) => Ok(()),
            Err(CompanionError::Operation(message)) if cancel.is_cancelled() => {
                self.jobs.set(&request_id, InstallState::Cancelled);
                Err(CompanionError::Operation(message))
            }
            Err(error) => {
                let code = error_code(&error).to_owned();
                self.jobs.set(
                    &request_id,
                    InstallState::Failed {
                        code,
                        message: error.to_string(),
                    },
                );
                Err(error)
            }
        }
    }

    async fn execute_inner(
        &self,
        file: &PathBuf,
        expected: &PackageExpectation,
        udid: &str,
        request_id: &str,
        cancel: &CancellationToken,
    ) -> Result<()> {
        if cancel.is_cancelled() {
            self.jobs.set(request_id, InstallState::Cancelled);
            return Err(CompanionError::Operation(
                "user cancelled installation".into(),
            ));
        }
        let devices = self.devices.clone();
        let file_for_validation = file.clone();
        let expected_for_validation = expected.clone();
        self.jobs.set(request_id, InstallState::Verifying);
        let validated: ValidatedPackage = task::spawn_blocking(move || {
            PackageValidator.validate(&file_for_validation, &expected_for_validation)
        })
        .await
        .map_err(|error| {
            CompanionError::Operation(format!("package validation task failed: {error}"))
        })??;
        let connected = devices.discover().await?;
        let device = connected
            .iter()
            .find(|device| device.udid.eq_ignore_ascii_case(udid) && device.trusted)
            .ok_or(CompanionError::DeviceUnavailable)?;
        if device.developer_mode == Some(false) {
            return Err(CompanionError::Operation("Developer Mode is off. Enable it in Settings → Privacy & Security, then restart the iPhone.".into()));
        }
        if cancel.is_cancelled() {
            return Err(CompanionError::Operation(
                "user cancelled installation".into(),
            ));
        }
        self.jobs.set(request_id, InstallState::Provisioning);
        self.signer.validate_provisioning(&validated, udid)?;
        if cancel.is_cancelled() {
            return Err(CompanionError::Operation(
                "user cancelled installation".into(),
            ));
        }
        self.jobs.set(request_id, InstallState::Signing);
        let signed = tokio::select! {
            _ = cancel.cancelled() => return Err(CompanionError::Operation("user cancelled installation".into())),
            result = self.signer.sign(&validated, udid) => result?,
        };
        if cancel.is_cancelled() {
            return Err(CompanionError::Operation(
                "user cancelled installation".into(),
            ));
        }
        self.jobs.set(request_id, InstallState::Installing);
        tokio::select! {
            _ = cancel.cancelled() => return Err(CompanionError::Operation("user cancelled installation".into())),
            result = self.devices.install(udid, &signed.path) => result?,
        }
        self.jobs.set(request_id, InstallState::Confirming);
        let inventory = self.devices.installed_apps(udid).await?;
        let installed = inventory.iter().find(|app| app.bundle_identifier == expected.bundle_identifier)
            .ok_or_else(|| CompanionError::Operation("device completed the install request but the app is absent from installed-app inventory".into()))?;
        if installed.version.as_deref() != Some(expected.version.as_str())
            || installed.build.as_deref() != Some(expected.build.as_str())
        {
            return Err(CompanionError::Operation(
                "the installed app version/build does not match the signed package".into(),
            ));
        }
        self.jobs.set(
            request_id,
            InstallState::Installed {
                app: installed.clone(),
                installed_at: Utc::now(),
                signing: signed.info,
            },
        );
        Ok(())
    }

    pub async fn inventory(&self, udid: &str) -> Result<Vec<crate::models::InstalledApp>> {
        self.devices.installed_apps(udid).await
    }

    pub async fn uninstall(&self, udid: &str, bundle_identifier: &str) -> Result<()> {
        self.devices.uninstall(udid, bundle_identifier).await?;
        let inventory = self.devices.installed_apps(udid).await?;
        if inventory
            .iter()
            .any(|app| app.bundle_identifier == bundle_identifier)
        {
            return Err(CompanionError::Operation(
                "uninstall request completed but the app remains in device inventory".into(),
            ));
        }
        Ok(())
    }
}

fn error_code(error: &CompanionError) -> &'static str {
    match error {
        CompanionError::ChecksumMismatch => "checksum_mismatch",
        CompanionError::MetadataMismatch => "metadata_mismatch",
        CompanionError::InvalidPackage(_) => "invalid_package",
        CompanionError::SigningRequired => "signing_required",
        CompanionError::DeviceUnavailable => "device_disconnected",
        CompanionError::InvalidPairingCode
        | CompanionError::AuthenticationFailed
        | CompanionError::PairingRequired => "authentication_failed",
        _ => "installation_failed",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        models::{DeviceInfo, InstalledApp, SignedPackage, SignedPackageInfo, SigningStatus},
        signing::zsign::SigningProvider,
    };
    use async_trait::async_trait;
    use sha2::Digest;
    use std::{
        path::Path,
        sync::atomic::{AtomicBool, Ordering},
    };
    use tempfile::tempdir;

    struct TestDevice {
        available: bool,
        install_succeeds: bool,
        inventory: Mutex<Vec<InstalledApp>>,
    }
    #[async_trait]
    impl DeviceProvider for TestDevice {
        async fn discover(&self) -> Result<Vec<DeviceInfo>> {
            if !self.available {
                return Ok(Vec::new());
            }
            Ok(vec![DeviceInfo {
                udid: "0123456789abcdef0123456789ABCDEF".into(),
                name: "Test iPhone".into(),
                product_type: None,
                product_version: Some("26.0".into()),
                build_version: None,
                developer_mode: Some(true),
                trusted: true,
            }])
        }
        async fn installed_apps(&self, _udid: &str) -> Result<Vec<InstalledApp>> {
            Ok(self.inventory.lock().unwrap().clone())
        }
        async fn install(&self, _udid: &str, _package: &Path) -> Result<()> {
            if self.install_succeeds {
                Ok(())
            } else {
                Err(CompanionError::Operation("install failed".into()))
            }
        }
        async fn uninstall(&self, _udid: &str, bundle: &str) -> Result<()> {
            self.inventory
                .lock()
                .unwrap()
                .retain(|app| app.bundle_identifier != bundle);
            Ok(())
        }
    }

    struct TestSigner {
        success: bool,
        provisioning_succeeds: bool,
        called: AtomicBool,
    }
    #[async_trait]
    impl SigningProvider for TestSigner {
        fn validate_provisioning(&self, _package: &ValidatedPackage, _udid: &str) -> Result<()> {
            if self.provisioning_succeeds {
                Ok(())
            } else {
                Err(CompanionError::Operation("provisioning failed".into()))
            }
        }
        fn validate_device(&self, _udid: &str) -> Result<()> {
            if self.provisioning_succeeds {
                Ok(())
            } else {
                Err(CompanionError::Operation("provisioning failed".into()))
            }
        }
        async fn sign(&self, package: &ValidatedPackage, _udid: &str) -> Result<SignedPackage> {
            self.called.store(true, Ordering::SeqCst);
            if !self.success {
                return Err(CompanionError::Operation("sign failed".into()));
            }
            Ok(SignedPackage {
                path: package.path.clone(),
                info: SignedPackageInfo {
                    bundle_identifier: package.metadata.bundle_identifier.clone(),
                    version: package.metadata.version.clone(),
                    build: package.metadata.build.clone(),
                    original_sha256: package.metadata.sha256.clone(),
                    signed_sha256: package.metadata.sha256.clone(),
                    signing_identity: "test-only signer".into(),
                    team_identifier: Some("TESTTEAM".into()),
                    certificate_expires_at: Some(Utc::now() + chrono::Duration::days(30)),
                    provisioning_expiration: None,
                    created_at: Utc::now(),
                },
            })
        }
        fn status(&self) -> SigningStatus {
            SigningStatus::not_configured()
        }
    }

    fn fixture() -> (tempfile::TempDir, PathBuf, PackageExpectation) {
        use std::io::Write;
        use zip::{ZipWriter, write::SimpleFileOptions};
        let dir = tempdir().unwrap();
        let path = dir.path().join("sample.ipa");
        let mut zip = ZipWriter::new(std::fs::File::create(&path).unwrap());
        zip.start_file(
            "Payload/Sample.app/Info.plist",
            SimpleFileOptions::default(),
        )
        .unwrap();
        let mut plist = plist::Dictionary::new();
        for (key, value) in [
            ("CFBundleIdentifier", "org.dreyze.sample"),
            ("CFBundleExecutable", "Sample"),
            ("CFBundleShortVersionString", "1.0.0"),
            ("CFBundleVersion", "1"),
            ("MinimumOSVersion", "16.0"),
        ] {
            plist.insert(key.into(), plist::Value::String(value.into()));
        }
        plist::Value::Dictionary(plist)
            .to_writer_xml(&mut zip)
            .unwrap();
        zip.start_file("Payload/Sample.app/Sample", SimpleFileOptions::default())
            .unwrap();
        zip.write_all(b"test executable").unwrap();
        zip.finish().unwrap();
        let data = std::fs::read(&path).unwrap();
        let expected = PackageExpectation {
            request_id: "test-install".into(),
            app_name: "Sample".into(),
            bundle_identifier: "org.dreyze.sample".into(),
            version: "1.0.0".into(),
            build: "1".into(),
            minimum_os_version: Some("16.0".into()),
            sha256: hex::encode(sha2::Sha256::digest(&data)),
            size: data.len() as u64,
        };
        (dir, path, expected)
    }

    #[tokio::test]
    async fn installed_state_requires_device_inventory_confirmation_after_sign_and_install() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(vec![InstalledApp {
                bundle_identifier: expected.bundle_identifier.clone(),
                version: Some(expected.version.clone()),
                build: Some(expected.build.clone()),
            }]),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        let coordinator = PackageInstallCoordinator::new(device, signer.clone(), jobs.clone());
        coordinator
            .execute(
                path,
                expected.clone(),
                "0123456789abcdef0123456789ABCDEF".into(),
                token,
            )
            .await
            .unwrap();
        assert!(matches!(
            jobs.get("test-install"),
            Some(InstallState::Installed { .. })
        ));
        assert!(signer.called.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn exit_code_without_inventory_does_not_report_installed() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(Vec::new()),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        let coordinator = PackageInstallCoordinator::new(device, signer, jobs.clone());
        assert!(
            coordinator
                .execute(
                    path,
                    expected,
                    "0123456789abcdef0123456789ABCDEF".into(),
                    token
                )
                .await
                .is_err()
        );
        assert!(matches!(
            jobs.get("test-install"),
            Some(InstallState::Failed { .. })
        ));
    }

    #[tokio::test]
    async fn disconnected_device_stops_before_signing() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: false,
            install_succeeds: true,
            inventory: Mutex::new(Vec::new()),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        let coordinator = PackageInstallCoordinator::new(device, signer.clone(), jobs);
        assert!(
            coordinator
                .execute(
                    path,
                    expected,
                    "0123456789abcdef0123456789ABCDEF".into(),
                    token
                )
                .await
                .is_err()
        );
        assert!(!signer.called.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn install_failure_never_returns_installed() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: false,
            inventory: Mutex::new(Vec::new()),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        let coordinator = PackageInstallCoordinator::new(device, signer, jobs.clone());
        assert!(
            coordinator
                .execute(
                    path,
                    expected,
                    "0123456789abcdef0123456789ABCDEF".into(),
                    token
                )
                .await
                .is_err()
        );
        assert!(matches!(
            jobs.get("test-install"),
            Some(InstallState::Failed { .. })
        ));
    }

    #[tokio::test]
    async fn provisioning_failure_stops_before_signing_or_installing() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(Vec::new()),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: false,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        let coordinator = PackageInstallCoordinator::new(device, signer.clone(), jobs.clone());
        assert!(
            coordinator
                .execute(
                    path,
                    expected,
                    "0123456789abcdef0123456789ABCDEF".into(),
                    token,
                )
                .await
                .is_err()
        );
        assert!(!signer.called.load(Ordering::SeqCst));
        assert!(matches!(
            jobs.get("test-install"),
            Some(InstallState::Failed { .. })
        ));
    }

    #[tokio::test]
    async fn signing_failure_never_reports_installed() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(Vec::new()),
        });
        let signer = Arc::new(TestSigner {
            success: false,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        let coordinator = PackageInstallCoordinator::new(device, signer.clone(), jobs.clone());
        assert!(
            coordinator
                .execute(
                    path,
                    expected,
                    "0123456789abcdef0123456789ABCDEF".into(),
                    token,
                )
                .await
                .is_err()
        );
        assert!(signer.called.load(Ordering::SeqCst));
        assert!(matches!(
            jobs.get("test-install"),
            Some(InstallState::Failed { .. })
        ));
    }

    #[tokio::test]
    async fn cancelled_install_stays_cancelled_and_never_signs() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(Vec::new()),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        token.cancel();
        let coordinator = PackageInstallCoordinator::new(device, signer.clone(), jobs.clone());
        assert!(
            coordinator
                .execute(
                    path,
                    expected,
                    "0123456789abcdef0123456789ABCDEF".into(),
                    token,
                )
                .await
                .is_err()
        );
        assert!(!signer.called.load(Ordering::SeqCst));
        assert_eq!(jobs.get("test-install"), Some(InstallState::Cancelled));
    }

    #[tokio::test]
    async fn uninstall_requires_app_to_disappear_from_inventory() {
        let app = InstalledApp {
            bundle_identifier: "org.dreyze.sample".into(),
            version: Some("1.0".into()),
            build: Some("1".into()),
        };
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(vec![app]),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let coordinator =
            PackageInstallCoordinator::new(device, signer, InstallJobStore::default());
        coordinator
            .uninstall("0123456789abcdef0123456789ABCDEF", "org.dreyze.sample")
            .await
            .unwrap();
    }
}
