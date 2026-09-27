use crate::{
    error::{CompanionError, Result},
    models::{PackageMetadata, SignedPackage, SignedPackageInfo, SigningStatus, ValidatedPackage},
    package::validator::PackageValidator,
    security::secrets::{
        P12Certificate, SigningIdentityVault, SigningMaterial, inspect_p12_certificates,
    },
};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncWriteExt, process::Command, time::timeout};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

const SIGN_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const MAX_PASSWORD_BYTES: usize = 2048;

#[async_trait]
pub trait SigningProvider: Send + Sync {
    fn validate_provisioning(&self, package: &ValidatedPackage, target_udid: &str) -> Result<()>;
    fn validate_device(&self, target_udid: &str) -> Result<()>;
    async fn sign(&self, package: &ValidatedPackage, target_udid: &str) -> Result<SignedPackage>;
    fn status(&self) -> SigningStatus;
}

#[derive(Clone, Debug)]
pub struct AppleDevelopmentSigningProvider {
    zsign: PathBuf,
    vault: SigningIdentityVault,
    package_root: PathBuf,
}

impl AppleDevelopmentSigningProvider {
    pub fn new(zsign: PathBuf, vault: SigningIdentityVault, package_root: PathBuf) -> Self {
        Self {
            zsign,
            vault,
            package_root,
        }
    }

    pub fn from_current_executable(vault: SigningIdentityVault, package_root: PathBuf) -> Self {
        let from_env = std::env::var_os("DREYZE_ZSIGN_PATH").map(PathBuf::from);
        let candidates = std::env::current_exe()
            .ok()
            .and_then(|path| {
                path.parent().map(|parent| {
                    vec![
                        parent.join("resources/binaries/zsign-x86_64-pc-windows-msvc.exe"),
                        parent.join("binaries/zsign-x86_64-pc-windows-msvc.exe"),
                        parent.join("zsign-x86_64-pc-windows-msvc.exe"),
                    ]
                })
            })
            .unwrap_or_default();
        let bundled = candidates.into_iter().find(|path| path.is_file());
        let zsign = from_env
            .or(bundled)
            .unwrap_or_else(|| PathBuf::from("zsign-x86_64-pc-windows-msvc.exe"));
        Self::new(zsign, vault, package_root)
    }

    fn command_args(
        &self,
        p12: &Path,
        profile: &Path,
        output: &Path,
        input_folder: &Path,
        temp: &Path,
    ) -> Vec<String> {
        vec![
            "--force".into(),
            "--check".into(),
            "--pkey".into(),
            p12.to_string_lossy().into_owned(),
            "--prov".into(),
            profile.to_string_lossy().into_owned(),
            "--password-stdin".into(),
            "--temp_folder".into(),
            temp.to_string_lossy().into_owned(),
            "--output".into(),
            output.to_string_lossy().into_owned(),
            input_folder.to_string_lossy().into_owned(),
        ]
    }

    fn load_validated_identity(
        &self,
    ) -> Result<(SigningMaterial, ProvisioningProfile, P12Certificate)> {
        let material = self.vault.load()?;
        let profile = parse_mobileprovision(&material.mobileprovision)?;
        let certificates = inspect_p12_certificates(&material.p12, &material.password)?;
        let certificate = certificates
            .into_iter()
            .find(|certificate| profile.authorizes_certificate(&certificate.der))
            .ok_or_else(|| {
                CompanionError::Operation(
                    "the P12 Apple Development certificate is not authorized by the imported provisioning profile".into(),
                )
            })?;
        Ok((material, profile, certificate))
    }

    fn validate_certificate_current(certificate: &P12Certificate) -> Result<()> {
        if certificate.expires_at <= Utc::now() {
            return Err(CompanionError::Operation(
                "the Apple Development certificate has expired".into(),
            ));
        }
        Ok(())
    }

    async fn run_signer(&self, args: &[String], password: &mut Zeroizing<String>) -> Result<()> {
        if !self.zsign.is_file() {
            return Err(CompanionError::Operation(
                "the packaged zsign signing engine is unavailable".into(),
            ));
        }
        if password.as_bytes().is_empty() || password.len() > MAX_PASSWORD_BYTES {
            return Err(CompanionError::InvalidRequest(
                "invalid P12 password length".into(),
            ));
        }
        let mut child = Command::new(&self.zsign)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| {
                CompanionError::Operation(format!("could not start local signing engine: {error}"))
            })?;
        let mut stdin = child.stdin.take().ok_or_else(|| {
            CompanionError::Operation("signing engine input pipe unavailable".into())
        })?;
        let bytes = password.as_bytes();
        stdin.write_all(&(bytes.len() as u32).to_le_bytes()).await?;
        stdin.write_all(bytes).await?;
        stdin.shutdown().await?;
        password.zeroize();
        let output = timeout(SIGN_TIMEOUT, child.wait_with_output())
            .await
            .map_err(|_| CompanionError::Operation("local signing operation timed out".into()))?
            .map_err(|error| {
                CompanionError::Operation(format!("signing engine failed to run: {error}"))
            })?;
        if !output.status.success() {
            let detail = String::from_utf8_lossy(&output.stderr);
            let summary = detail.lines().take(6).collect::<Vec<_>>().join(" ");
            return Err(CompanionError::Operation(if summary.is_empty() {
                "Apple development signing failed".into()
            } else {
                summary
            }));
        }
        Ok(())
    }
}

#[async_trait]
impl SigningProvider for AppleDevelopmentSigningProvider {
    fn validate_provisioning(&self, package: &ValidatedPackage, target_udid: &str) -> Result<()> {
        let (_material, profile, certificate) = self.load_validated_identity()?;
        Self::validate_certificate_current(&certificate)?;
        validate_profile(&profile, &package.metadata.bundle_identifier, target_udid)
    }

    fn validate_device(&self, target_udid: &str) -> Result<()> {
        let (_material, profile, certificate) = self.load_validated_identity()?;
        Self::validate_certificate_current(&certificate)?;
        validate_profile_device(&profile, target_udid)
    }

    async fn sign(&self, package: &ValidatedPackage, target_udid: &str) -> Result<SignedPackage> {
        let (material, profile, certificate) = self.load_validated_identity()?;
        Self::validate_certificate_current(&certificate)?;
        validate_profile(&profile, &package.metadata.bundle_identifier, target_udid)?;
        fs::create_dir_all(&self.package_root)?;
        let job = self.package_root.join(Uuid::new_v4().to_string());
        fs::create_dir(&job)?;
        let cleanup = ScopedDirectory(job.clone());
        let input_file = job.join("signing-identity.p12");
        let profile_file = job.join("provision.mobileprovision");
        let input_folder = job.join("expanded");
        let output_file = job.join("signed.ipa");
        let temp = job.join("zsign-temp");
        fs::create_dir(&temp)?;
        fs::write(&input_file, &*material.p12)?;
        fs::write(&profile_file, &*material.mobileprovision)?;
        let validator = PackageValidator;
        validator.extract_for_signing(package, &input_folder)?;
        let args = self.command_args(
            &input_file,
            &profile_file,
            &output_file,
            &input_folder,
            &temp,
        );
        let mut password = material.password;
        self.run_signer(&args, &mut password).await?;

        let signed_metadata = validator.inspect(&output_file)?;
        verify_signed_metadata(&package.metadata, &signed_metadata)?;
        let check_args = vec!["--check".into(), output_file.to_string_lossy().into_owned()];
        self.run_signature_check(&check_args).await?;

        let signed_directory = self.package_root.join("signed");
        fs::create_dir_all(&signed_directory)?;
        let final_path = signed_directory.join(format!("{}.ipa", Uuid::new_v4()));
        fs::rename(&output_file, &final_path)?;
        let info = SignedPackageInfo {
            bundle_identifier: signed_metadata.bundle_identifier,
            version: signed_metadata.version,
            build: signed_metadata.build,
            original_sha256: package.metadata.sha256.clone(),
            signed_sha256: signed_metadata.sha256,
            signing_identity: profile.name,
            team_identifier: Some(profile.team_id),
            certificate_expires_at: Some(certificate.expires_at),
            provisioning_expiration: Some(profile.expiration),
            created_at: Utc::now(),
        };
        drop(cleanup);
        Ok(SignedPackage {
            path: final_path,
            info,
        })
    }

    fn status(&self) -> SigningStatus {
        match self.load_validated_identity() {
            Ok((_material, profile, certificate)) => {
                let profile_expired = profile.expiration <= Utc::now();
                let certificate_expired = certificate.expires_at <= Utc::now();
                SigningStatus {
                    configured: !profile_expired && !certificate_expired,
                    identity_label: Some(profile.name),
                    certificate_expires_at: Some(certificate.expires_at),
                    provisioning_expires_at: Some(profile.expiration),
                    team_id: Some(profile.team_id),
                    account_kind: Some("Imported Apple Development identity".into()),
                    limitation: Some(if certificate_expired {
                        "The imported Apple Development certificate has expired. Import a current certificate and matching provisioning profile.".into()
                    } else if profile_expired {
                        "The imported provisioning profile has expired. Import a current profile for this iPhone and app identifier.".into()
                    } else {
                        "The local P12 certificate matches the imported provisioning profile. The connected device and requested app identifier are checked for each install. Apple Account provisioning is not automated on Windows.".into()
                    }),
                }
            }
            Err(_error) if !self.vault.is_configured() => SigningStatus::not_configured(),
            Err(error) => SigningStatus {
                configured: false,
                identity_label: None,
                certificate_expires_at: None,
                provisioning_expires_at: None,
                team_id: None,
                account_kind: Some("Imported local signing identity".into()),
                limitation: Some(error.to_string()),
            },
        }
    }
}

impl AppleDevelopmentSigningProvider {
    async fn run_signature_check(&self, args: &[String]) -> Result<()> {
        if !self.zsign.is_file() {
            return Err(CompanionError::Operation(
                "the packaged zsign signing engine is unavailable".into(),
            ));
        }
        let output = timeout(
            SIGN_TIMEOUT,
            Command::new(&self.zsign)
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .output(),
        )
        .await
        .map_err(|_| CompanionError::Operation("signature verification timed out".into()))?
        .map_err(|error| {
            CompanionError::Operation(format!("signature verifier could not run: {error}"))
        })?;
        if !output.status.success() {
            return Err(CompanionError::Operation("zsign could not validate the signature or signing certificate (including OCSP status)".into()));
        }
        Ok(())
    }
}

fn verify_signed_metadata(original: &PackageMetadata, signed: &PackageMetadata) -> Result<()> {
    if original.bundle_identifier != signed.bundle_identifier
        || original.version != signed.version
        || original.build != signed.build
        || original.minimum_os_version != signed.minimum_os_version
    {
        return Err(CompanionError::MetadataMismatch);
    }
    Ok(())
}

fn validate_profile(
    profile: &ProvisioningProfile,
    bundle_identifier: &str,
    target_udid: &str,
) -> Result<()> {
    if !profile.authorizes_bundle(bundle_identifier) {
        return Err(CompanionError::Operation(
            "the provisioning profile does not authorize this bundle identifier".into(),
        ));
    }
    validate_profile_device(profile, target_udid)
}

fn validate_profile_device(profile: &ProvisioningProfile, target_udid: &str) -> Result<()> {
    if !profile
        .provisioned_devices
        .iter()
        .any(|udid| udid.eq_ignore_ascii_case(target_udid))
    {
        return Err(CompanionError::Operation(
            "the selected iPhone is not registered in this provisioning profile".into(),
        ));
    }
    if profile.expiration <= Utc::now() {
        return Err(CompanionError::Operation(
            "the provisioning profile has expired".into(),
        ));
    }
    Ok(())
}

#[derive(Debug)]
struct ProvisioningProfile {
    name: String,
    team_id: String,
    app_identifier: String,
    provisioned_devices: Vec<String>,
    developer_certificates: Vec<Vec<u8>>,
    expiration: DateTime<Utc>,
}

impl ProvisioningProfile {
    fn authorizes_bundle(&self, bundle_id: &str) -> bool {
        let suffix = self
            .app_identifier
            .split_once('.')
            .map(|(_, suffix)| suffix)
            .unwrap_or_default();
        if suffix == "*" {
            return true;
        }
        if let Some(prefix) = suffix.strip_suffix(".*") {
            return bundle_id == prefix || bundle_id.starts_with(&format!("{prefix}."));
        }
        suffix == bundle_id && !self.team_id.is_empty()
    }

    fn authorizes_certificate(&self, certificate_der: &[u8]) -> bool {
        self.developer_certificates
            .iter()
            .any(|allowed| allowed.as_slice() == certificate_der)
    }
}

fn parse_mobileprovision(bytes: &[u8]) -> Result<ProvisioningProfile> {
    let marker = b"<?xml";
    let start = bytes
        .windows(marker.len())
        .position(|window| window == marker)
        .ok_or_else(|| {
            CompanionError::Operation(
                "the provisioning profile does not contain an XML property list".into(),
            )
        })?;
    let data = &bytes[start..];
    let end_marker = b"</plist>";
    let end = data
        .windows(end_marker.len())
        .position(|window| window == end_marker)
        .map(|offset| offset + end_marker.len())
        .ok_or_else(|| {
            CompanionError::Operation("the provisioning profile property list is truncated".into())
        })?;
    let value: plist::Value = plist::from_bytes(&data[..end]).map_err(|_| {
        CompanionError::Operation("the provisioning profile property list is malformed".into())
    })?;
    let root = value.as_dictionary().ok_or_else(|| {
        CompanionError::Operation("provisioning profile is not a property list dictionary".into())
    })?;
    let entitlements = root
        .get("Entitlements")
        .and_then(plist::Value::as_dictionary)
        .ok_or_else(|| {
            CompanionError::Operation("provisioning profile has no app entitlements".into())
        })?;
    let app_identifier = entitlements
        .get("application-identifier")
        .and_then(plist::Value::as_string)
        .ok_or_else(|| {
            CompanionError::Operation("provisioning profile has no application identifier".into())
        })?
        .to_owned();
    let team_id = root
        .get("TeamIdentifier")
        .and_then(plist::Value::as_array)
        .and_then(|values| values.first())
        .and_then(plist::Value::as_string)
        .unwrap_or_default()
        .to_owned();
    let name = root
        .get("Name")
        .and_then(plist::Value::as_string)
        .unwrap_or("Apple Development Profile")
        .to_owned();
    let expiration = root
        .get("ExpirationDate")
        .and_then(plist::Value::as_date)
        .map(|date| DateTime::<Utc>::from(std::time::SystemTime::from(date)))
        .ok_or_else(|| {
            CompanionError::Operation("provisioning profile expiration is missing".into())
        })?;
    let provisioned_devices = root
        .get("ProvisionedDevices")
        .and_then(plist::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(plist::Value::as_string)
        .map(ToOwned::to_owned)
        .collect();
    let developer_certificates = root
        .get("DeveloperCertificates")
        .and_then(plist::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(plist::Value::as_data)
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    if team_id.is_empty() || !app_identifier.contains('.') || developer_certificates.is_empty() {
        return Err(CompanionError::Operation(
            "provisioning profile metadata is incomplete".into(),
        ));
    }
    Ok(ProvisioningProfile {
        name,
        team_id,
        app_identifier,
        provisioned_devices,
        developer_certificates,
        expiration,
    })
}

struct ScopedDirectory(PathBuf);
impl Drop for ScopedDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zsign_process_arguments_never_include_password() {
        let provider = AppleDevelopmentSigningProvider::new(
            "zsign.exe".into(),
            SigningIdentityVault::new("vault".into()),
            "packages".into(),
        );
        let args = provider.command_args(
            Path::new("cert.p12"),
            Path::new("profile.mobileprovision"),
            Path::new("out.ipa"),
            Path::new("work"),
            Path::new("temp"),
        );
        assert!(args.iter().any(|arg| arg == "--password-stdin"));
        assert!(!args.iter().any(|arg| arg == "secret"));
        assert!(!args.join(" ").contains("password=secret"));
    }

    #[test]
    fn package_identity_must_not_change_during_resigning() {
        let original = PackageMetadata {
            bundle_identifier: "com.example.app".into(),
            version: "1.0".into(),
            build: "1".into(),
            minimum_os_version: Some("16.0".into()),
            app_name: None,
            size: 10,
            sha256: "a".repeat(64),
        };
        let mut signed = original.clone();
        verify_signed_metadata(&original, &signed).unwrap();
        signed.bundle_identifier = "com.other.app".into();
        assert!(matches!(
            verify_signed_metadata(&original, &signed),
            Err(CompanionError::MetadataMismatch)
        ));
    }

    #[test]
    fn profile_must_cover_exact_bundle_and_registered_device() {
        let profile = ProvisioningProfile {
            name: "Development".into(),
            team_id: "TEAM123".into(),
            app_identifier: "TEAM123.com.example.*".into(),
            provisioned_devices: vec!["ABC123".into()],
            developer_certificates: vec![vec![1, 2, 3]],
            expiration: Utc::now() + chrono::Duration::days(3),
        };
        assert!(profile.authorizes_bundle("com.example.reader"));
        assert!(!profile.authorizes_bundle("com.other.reader"));
        assert!(profile.authorizes_certificate(&[1, 2, 3]));
        assert!(!profile.authorizes_certificate(&[3, 2, 1]));
        assert!(
            profile
                .provisioned_devices
                .iter()
                .any(|device| device == "ABC123")
        );
    }

    #[test]
    fn expired_profile_is_rejected_for_installation() {
        let profile = ProvisioningProfile {
            name: "Expired Development".into(),
            team_id: "TEAM123".into(),
            app_identifier: "TEAM123.org.dreyze.sample".into(),
            provisioned_devices: vec!["0123456789abcdef0123456789ABCDEF".into()],
            developer_certificates: vec![vec![1, 2, 3]],
            expiration: Utc::now() - chrono::Duration::days(1),
        };
        assert!(
            validate_profile(
                &profile,
                "org.dreyze.sample",
                "0123456789abcdef0123456789ABCDEF"
            )
            .is_err()
        );
    }

    #[test]
    fn expired_development_certificate_is_rejected() {
        let certificate = P12Certificate {
            der: vec![1, 2, 3],
            expires_at: Utc::now() - chrono::Duration::seconds(1),
        };
        assert!(
            AppleDevelopmentSigningProvider::validate_certificate_current(&certificate).is_err()
        );
    }

    #[test]
    fn mobileprovision_parser_extracts_team_bundle_device_certificate_and_expiry() {
        let mut entitlements = plist::Dictionary::new();
        entitlements.insert(
            "application-identifier".into(),
            plist::Value::String("TEAM123.org.dreyze.test.sample".into()),
        );
        let mut root = plist::Dictionary::new();
        root.insert(
            "Entitlements".into(),
            plist::Value::Dictionary(entitlements),
        );
        root.insert(
            "TeamIdentifier".into(),
            plist::Value::Array(vec![plist::Value::String("TEAM123".into())]),
        );
        root.insert(
            "Name".into(),
            plist::Value::String("Dreyze Test Development".into()),
        );
        root.insert(
            "ExpirationDate".into(),
            plist::Value::Date(plist::Date::from(
                std::time::SystemTime::now() + std::time::Duration::from_secs(3600),
            )),
        );
        root.insert(
            "ProvisionedDevices".into(),
            plist::Value::Array(vec![plist::Value::String(
                "0123456789abcdef0123456789abcdef".into(),
            )]),
        );
        root.insert(
            "DeveloperCertificates".into(),
            plist::Value::Array(vec![plist::Value::Data(vec![1, 2, 3])]),
        );
        let mut bytes = Vec::new();
        plist::Value::Dictionary(root)
            .to_writer_xml(&mut bytes)
            .unwrap();

        let profile = parse_mobileprovision(&bytes).unwrap();
        assert_eq!(profile.team_id, "TEAM123");
        assert_eq!(profile.name, "Dreyze Test Development");
        assert!(profile.authorizes_bundle("org.dreyze.test.sample"));
        assert!(profile.authorizes_certificate(&[1, 2, 3]));
        assert!(profile.expiration > Utc::now());
        assert!(validate_profile_device(&profile, "0123456789abcdef0123456789abcdef").is_ok());
        assert!(validate_profile_device(&profile, "ffffffffffffffffffffffffffffffff").is_err());
    }
}
