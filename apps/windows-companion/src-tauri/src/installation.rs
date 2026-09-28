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
        let _signed_output_cleanup = SignedOutputCleanup(signed.path.clone());
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
        let installed = inventory.iter().find(|app| app.bundle_identifier == signed.info.bundle_identifier)
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

/// Removes only signer-generated UUID outputs from the two managed output
/// directories. A signer returning an unrelated path cannot make cleanup
/// delete arbitrary user files.
struct SignedOutputCleanup(PathBuf);

impl Drop for SignedOutputCleanup {
    fn drop(&mut self) {
        let Some(parent) = self.0.parent() else {
            return;
        };
        if !matches!(
            parent.file_name().and_then(|name| name.to_str()),
            Some("signed" | "signed-apple-account")
        ) {
            return;
        }
        let Some(name) = self.0.file_name().and_then(|name| name.to_str()) else {
            return;
        };
        let Some(stem) = PathBuf::from(name)
            .file_stem()
            .and_then(|part| part.to_str())
            .map(ToOwned::to_owned)
        else {
            return;
        };
        let extension = self.0.extension().and_then(|part| part.to_str());
        if uuid::Uuid::parse_str(&stem).is_err() || !matches!(extension, Some("ipa" | "app")) {
            return;
        }
        match std::fs::symlink_metadata(&self.0) {
            Ok(metadata) if metadata.file_type().is_dir() => {
                let _ = std::fs::remove_dir_all(&self.0);
            }
            Ok(metadata) if metadata.file_type().is_file() => {
                let _ = std::fs::remove_file(&self.0);
            }
            _ => {}
        }
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
        inventory_after_install: Mutex<Option<Vec<InstalledApp>>>,
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
                if let Some(installed) = self.inventory_after_install.lock().unwrap().take() {
                    *self.inventory.lock().unwrap() = installed;
                }
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
        fixture_version("1.0.0", "1")
    }

    fn fixture_version(
        version: &str,
        build: &str,
    ) -> (tempfile::TempDir, PathBuf, PackageExpectation) {
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
            ("CFBundleShortVersionString", version),
            ("CFBundleVersion", build),
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
            version: version.into(),
            build: build.into(),
            minimum_os_version: Some("16.0".into()),
            sha256: hex::encode(sha2::Sha256::digest(&data)),
            size: data.len() as u64,
        };
        (dir, path, expected)
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    enum MockAppleState {
        SignedOut,
        TwoFactorPending,
        Authenticated,
        TeamSelected,
        DeviceRegistered,
        CertificateReady,
        ProfileReady { original: String, signed: String },
    }

    /// Test-only Apple developer service. It never connects to Apple and uses
    /// generated IPA fixtures; production commands are not wired to this type.
    struct MockAppleDeveloperService {
        state: Mutex<MockAppleState>,
        team_id: String,
        udid: String,
        output_root: PathBuf,
    }

    impl MockAppleDeveloperService {
        fn new(output_root: PathBuf) -> Self {
            Self {
                state: Mutex::new(MockAppleState::SignedOut),
                team_id: "ABCDE12345".into(),
                udid: "0123456789abcdef0123456789ABCDEF".into(),
                output_root,
            }
        }

        fn authenticate(&self, account: &str, password: &str) -> Result<()> {
            if !account.contains('@') || password.is_empty() {
                return Err(CompanionError::Operation(
                    "mock Apple authentication failed".into(),
                ));
            }
            *self.state.lock().unwrap() = MockAppleState::TwoFactorPending;
            Ok(())
        }

        fn submit_two_factor(&self, code: &str) -> Result<()> {
            if *self.state.lock().unwrap() != MockAppleState::TwoFactorPending || code != "123456" {
                return Err(CompanionError::Operation(
                    "mock Apple verification code rejected".into(),
                ));
            }
            *self.state.lock().unwrap() = MockAppleState::Authenticated;
            Ok(())
        }

        fn list_teams(&self) -> Result<Vec<String>> {
            if *self.state.lock().unwrap() != MockAppleState::Authenticated {
                return Err(CompanionError::SigningRequired);
            }
            Ok(vec![self.team_id.clone()])
        }

        fn select_team(&self, team: &str) -> Result<()> {
            if team != self.team_id || *self.state.lock().unwrap() != MockAppleState::Authenticated
            {
                return Err(CompanionError::SigningRequired);
            }
            *self.state.lock().unwrap() = MockAppleState::TeamSelected;
            Ok(())
        }

        fn register_device(&self, udid: &str, user_confirmed: bool) -> Result<()> {
            if udid != self.udid
                || !user_confirmed
                || *self.state.lock().unwrap() != MockAppleState::TeamSelected
            {
                return Err(CompanionError::DeviceUnavailable);
            }
            *self.state.lock().unwrap() = MockAppleState::DeviceRegistered;
            Ok(())
        }

        fn prepare_certificate(&self) -> Result<()> {
            if *self.state.lock().unwrap() != MockAppleState::DeviceRegistered {
                return Err(CompanionError::SigningRequired);
            }
            *self.state.lock().unwrap() = MockAppleState::CertificateReady;
            Ok(())
        }

        fn create_app_id_and_profile(&self, original: &str) -> Result<String> {
            if *self.state.lock().unwrap() != MockAppleState::CertificateReady {
                return Err(CompanionError::SigningRequired);
            }
            let signed = format!("{original}.{}", self.team_id);
            *self.state.lock().unwrap() = MockAppleState::ProfileReady {
                original: original.into(),
                signed: signed.clone(),
            };
            Ok(signed)
        }
    }

    #[async_trait]
    impl SigningProvider for MockAppleDeveloperService {
        fn validate_provisioning(&self, package: &ValidatedPackage, udid: &str) -> Result<()> {
            match &*self.state.lock().unwrap() {
                MockAppleState::ProfileReady { original, .. }
                    if original == &package.metadata.bundle_identifier && udid == self.udid =>
                {
                    Ok(())
                }
                _ => Err(CompanionError::SigningRequired),
            }
        }

        fn validate_device(&self, udid: &str) -> Result<()> {
            if udid == self.udid
                && matches!(
                    *self.state.lock().unwrap(),
                    MockAppleState::ProfileReady { .. }
                )
            {
                Ok(())
            } else {
                Err(CompanionError::DeviceUnavailable)
            }
        }

        async fn sign(&self, package: &ValidatedPackage, _udid: &str) -> Result<SignedPackage> {
            let signed_bundle = match &*self.state.lock().unwrap() {
                MockAppleState::ProfileReady { original, signed }
                    if original == &package.metadata.bundle_identifier =>
                {
                    signed.clone()
                }
                _ => return Err(CompanionError::SigningRequired),
            };
            let output = self.output_root.join("signed");
            std::fs::create_dir_all(&output)?;
            let signed_path = output.join(format!("{}.ipa", uuid::Uuid::new_v4()));
            std::fs::copy(&package.path, &signed_path)?;
            Ok(SignedPackage {
                path: signed_path,
                info: SignedPackageInfo {
                    bundle_identifier: signed_bundle,
                    version: package.metadata.version.clone(),
                    build: package.metadata.build.clone(),
                    original_sha256: package.metadata.sha256.clone(),
                    signed_sha256: package.metadata.sha256.clone(),
                    signing_identity: "test-only mock Apple team".into(),
                    team_identifier: Some(self.team_id.clone()),
                    certificate_expires_at: Some(Utc::now() + chrono::Duration::days(30)),
                    provisioning_expiration: Some(Utc::now() + chrono::Duration::days(7)),
                    created_at: Utc::now(),
                },
            })
        }

        fn status(&self) -> SigningStatus {
            SigningStatus::not_configured()
        }
    }

    #[test]
    fn signed_output_cleanup_removes_only_uuid_outputs_from_managed_signer_dirs() {
        let temp = tempdir().unwrap();
        let managed = temp.path().join("signed-apple-account");
        std::fs::create_dir_all(&managed).unwrap();
        let signed_app = managed.join(format!("{}.app", uuid::Uuid::new_v4()));
        std::fs::create_dir(&signed_app).unwrap();
        std::fs::write(signed_app.join("marker"), b"signed").unwrap();
        let unrelated = temp.path().join("user-file.ipa");
        std::fs::write(&unrelated, b"keep").unwrap();

        drop(SignedOutputCleanup(signed_app.clone()));

        assert!(!signed_app.exists());
        assert!(unrelated.exists());
    }

    #[tokio::test]
    async fn mock_apple_provisioning_install_refresh_update_and_uninstall_e2e() {
        const UDID: &str = "0123456789abcdef0123456789ABCDEF";
        let (dir, first_path, mut first) = fixture_version("1.0.0", "1");
        let (_update_dir, update_path, mut update) = fixture_version("2.0.0", "2");
        first.request_id = "mock-install".into();
        update.request_id = "mock-update".into();
        let signed_bundle = "org.dreyze.sample.ABCDE12345".to_owned();
        let mock_apple = Arc::new(MockAppleDeveloperService::new(dir.path().to_owned()));

        mock_apple
            .authenticate("developer@example.test", "test-only-password")
            .unwrap();
        assert_eq!(
            *mock_apple.state.lock().unwrap(),
            MockAppleState::TwoFactorPending
        );
        assert!(mock_apple.submit_two_factor("000000").is_err());
        mock_apple.submit_two_factor("123456").unwrap();
        assert_eq!(mock_apple.list_teams().unwrap(), vec!["ABCDE12345"]);
        mock_apple.select_team("ABCDE12345").unwrap();
        mock_apple.register_device(UDID, true).unwrap();
        mock_apple.prepare_certificate().unwrap();
        assert_eq!(
            mock_apple
                .create_app_id_and_profile(&first.bundle_identifier)
                .unwrap(),
            signed_bundle
        );

        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(Vec::new()),
            inventory_after_install: Mutex::new(Some(vec![InstalledApp {
                bundle_identifier: signed_bundle.clone(),
                version: Some(first.version.clone()),
                build: Some(first.build.clone()),
            }])),
        });
        let jobs = InstallJobStore::default();
        let coordinator =
            PackageInstallCoordinator::new(device.clone(), mock_apple.clone(), jobs.clone());
        let install_token = jobs.insert(first.request_id.clone()).unwrap();
        coordinator
            .execute(
                first_path.clone(),
                first.clone(),
                UDID.into(),
                install_token,
            )
            .await
            .unwrap();
        assert!(matches!(
            jobs.get("mock-install"),
            Some(InstallState::Installed { .. })
        ));
        assert_eq!(
            coordinator.inventory(UDID).await.unwrap()[0].bundle_identifier,
            signed_bundle
        );

        // Simulate refreshing the per-app profile: preserve app identity, then
        // reinstall and confirm the same version from device inventory.
        mock_apple
            .state
            .lock()
            .unwrap()
            .clone_from(&MockAppleState::CertificateReady);
        mock_apple
            .create_app_id_and_profile(&first.bundle_identifier)
            .unwrap();
        *device.inventory_after_install.lock().unwrap() = Some(vec![InstalledApp {
            bundle_identifier: signed_bundle.clone(),
            version: Some(first.version.clone()),
            build: Some(first.build.clone()),
        }]);
        first.request_id = "mock-refresh".into();
        let refresh_token = jobs.insert(first.request_id.clone()).unwrap();
        coordinator
            .execute(first_path, first.clone(), UDID.into(), refresh_token)
            .await
            .unwrap();
        assert!(matches!(
            jobs.get("mock-refresh"),
            Some(InstallState::Installed { .. })
        ));

        *device.inventory_after_install.lock().unwrap() = Some(vec![InstalledApp {
            bundle_identifier: signed_bundle.clone(),
            version: Some(update.version.clone()),
            build: Some(update.build.clone()),
        }]);
        update.request_id = "mock-update".into();
        let update_token = jobs.insert(update.request_id.clone()).unwrap();
        coordinator
            .execute(update_path, update.clone(), UDID.into(), update_token)
            .await
            .unwrap();
        let confirmed = coordinator.inventory(UDID).await.unwrap();
        assert_eq!(confirmed[0].version.as_deref(), Some("2.0.0"));
        assert_eq!(confirmed[0].build.as_deref(), Some("2"));
        assert!(matches!(
            jobs.get("mock-update"),
            Some(InstallState::Installed { .. })
        ));

        coordinator.uninstall(UDID, &signed_bundle).await.unwrap();
        assert!(coordinator.inventory(UDID).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn update_replaces_old_inventory_only_after_install_then_confirms_new_version() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(vec![InstalledApp {
                bundle_identifier: expected.bundle_identifier.clone(),
                version: Some("1.0.0".into()),
                build: Some("13".into()),
            }]),
            inventory_after_install: Mutex::new(Some(vec![InstalledApp {
                bundle_identifier: expected.bundle_identifier.clone(),
                version: Some(expected.version.clone()),
                build: Some(expected.build.clone()),
            }])),
        });
        let signer = Arc::new(TestSigner {
            success: true,
            provisioning_succeeds: true,
            called: AtomicBool::new(false),
        });
        let jobs = InstallJobStore::default();
        let token = jobs.insert(expected.request_id.clone()).unwrap();
        let coordinator = PackageInstallCoordinator::new(device, signer.clone(), jobs.clone());
        assert_eq!(
            coordinator
                .inventory("0123456789abcdef0123456789ABCDEF")
                .await
                .unwrap()[0]
                .version
                .as_deref(),
            Some("1.0.0")
        );
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
        let confirmed = coordinator
            .inventory("0123456789abcdef0123456789ABCDEF")
            .await
            .unwrap();
        assert_eq!(
            confirmed[0].version.as_deref(),
            Some(expected.version.as_str())
        );
        assert_eq!(confirmed[0].build.as_deref(), Some(expected.build.as_str()));
        assert!(signer.called.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn exit_code_without_inventory_does_not_report_installed() {
        let (_dir, path, expected) = fixture();
        let device = Arc::new(TestDevice {
            available: true,
            install_succeeds: true,
            inventory: Mutex::new(Vec::new()),
            inventory_after_install: Mutex::new(None),
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
            inventory_after_install: Mutex::new(None),
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
            inventory_after_install: Mutex::new(None),
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
            inventory_after_install: Mutex::new(None),
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
            inventory_after_install: Mutex::new(None),
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
            inventory_after_install: Mutex::new(None),
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
            inventory_after_install: Mutex::new(None),
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
