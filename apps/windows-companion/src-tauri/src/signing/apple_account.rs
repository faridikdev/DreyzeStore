//! Local Apple Account provisioning for the Windows Companion.
//!
//! Apple authentication is performed by `isideload` directly against Apple.
//! The anisette provider receives only its protocol's ADI state; credentials
//! and the Xcode app token stay in Windows Credential Manager.

use crate::{
    error::{CompanionError, Result},
    models::{PackageMetadata, SignedPackage, SignedPackageInfo, SigningStatus, ValidatedPackage},
    package::validator::PackageValidator,
    security::secrets::WindowsCredentialStore,
    signing::zsign::SigningProvider,
};
use apple_codesign::MachOBinary;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{
        AppToken, AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse,
    },
    dev::{
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    sideload::{SideloaderBuilder, builder::MaxCertsBehavior},
    util::keyring_storage::KeyringStorage,
};
use serde::Serialize;
use std::{
    fs,
    path::{Component, Path, PathBuf},
    sync::Mutex,
    time::Duration,
};
use tauri::{AppHandle, Emitter};
use tokio::{
    sync::{Mutex as AsyncMutex, oneshot},
    time::timeout,
};
use uuid::Uuid;
use zeroize::Zeroizing;

const TOKEN_ACCOUNT: &str = "apple-account-session-token";
const ADSID_ACCOUNT: &str = "apple-account-session-adsid";
const EXPIRY_ACCOUNT: &str = "apple-account-session-expiry";
const EMAIL_ACCOUNT: &str = "apple-account-session-email";
const ANISETTE_URL_ACCOUNT: &str = "apple-account-anisette-url";
const TEAM_ACCOUNT: &str = "apple-account-selected-team";
const REGISTERED_DEVICES_ACCOUNT: &str = "apple-account-registered-devices";
const CERTIFICATE_EXPIRY_ACCOUNT: &str = "apple-account-certificate-expiry";
const ISIDELOAD_KEYRING_SERVICE: &str = "com.dreyzestore.companion.apple-provisioning";
const AUTH_TIMEOUT: Duration = Duration::from_secs(180);
const APPLE_OPERATION_TIMEOUT: Duration = Duration::from_secs(180);
const MACHINE_NAME: &str = "DreyzeStore Companion";

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppleTeamSummary {
    pub team_id: String,
    pub name: String,
    pub team_type: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppleAccountStatus {
    pub connected: bool,
    pub email: Option<String>,
    pub selected_team_id: Option<String>,
    pub anisette_url: Option<String>,
    pub state: &'static str,
    pub limitation: Option<String>,
}

/// App UI waits on a one-use challenge and never persists its response.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TwoFactorChallenge {
    pub retry_message: Option<String>,
    pub unknown: bool,
    pub sms: bool,
    pub numbers: Vec<TrustedPhoneOption>,
    pub selected_number_id: Option<u32>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedPhoneOption {
    pub id: u32,
    pub last_two_digits: String,
}

/// Provisioning boundary kept separate from UI and from signing-file import.
#[async_trait]
pub trait AppleAccountProvisioningProvider: Send + Sync {
    async fn authenticate(
        &self,
        app: AppHandle,
        email: String,
        password: Zeroizing<String>,
        anisette_url: String,
        anisette_trust_confirmed: bool,
    ) -> Result<AppleAccountStatus>;
    async fn submit_two_factor(&self, action: TwoFactorAction) -> Result<()>;
    async fn list_teams(&self) -> Result<Vec<AppleTeamSummary>>;
    async fn select_team(&self, team_id: &str) -> Result<AppleAccountStatus>;
    async fn register_device(
        &self,
        team_id: &str,
        device_name: &str,
        udid: &str,
        explicit_confirmation: bool,
    ) -> Result<()>;
    async fn prepare_signing_certificate(&self, udid: &str) -> Result<DateTime<Utc>>;
    fn is_device_registered(&self, udid: &str) -> bool;
    async fn sign_out(&self) -> Result<()>;
    fn status(&self) -> AppleAccountStatus;
}

#[derive(Debug)]
pub enum TwoFactorAction {
    SubmitCode(Zeroizing<String>),
    SendSms(u32),
    SendToDevices,
    ResendCode,
    Cancel,
}

pub struct IsideloadAppleAccountProvider {
    session: AsyncMutex<Option<DeveloperSession>>,
    pending_challenge: AsyncMutex<Option<oneshot::Sender<TwoFactorCallbackResponse>>>,
    auth_state: Mutex<&'static str>,
    packages_root: PathBuf,
}

impl IsideloadAppleAccountProvider {
    pub fn new(packages_root: PathBuf) -> Self {
        Self {
            session: AsyncMutex::new(None),
            pending_challenge: AsyncMutex::new(None),
            auth_state: Mutex::new("idle"),
            packages_root,
        }
    }

    fn set_state(&self, state: &'static str) {
        *self
            .auth_state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = state;
    }

    fn read_credential(name: &str) -> Result<Option<String>> {
        WindowsCredentialStore::get(name)
    }

    fn save_credential(name: &str, value: &str) -> Result<()> {
        WindowsCredentialStore::set(name, value)
    }

    fn validate_anisette_url(value: &str) -> Result<String> {
        let parsed = reqwest::Url::parse(value.trim()).map_err(|_| {
            CompanionError::InvalidRequest("Enter a valid HTTPS anisette endpoint.".into())
        })?;
        if parsed.scheme() != "https"
            || parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            return Err(CompanionError::InvalidRequest(
                "The anisette provider must be an HTTPS URL without embedded credentials, query, or fragment.".into(),
            ));
        }
        Ok(parsed.as_str().trim_end_matches('/').to_owned())
    }

    fn anisette_provider(url: &str) -> Result<RemoteV3AnisetteProvider> {
        let storage = KeyringStorage::new(ISIDELOAD_KEYRING_SERVICE.to_owned());
        RemoteV3AnisetteProvider::new(url, Box::new(storage), "0".to_owned()).map_err(|_| {
            CompanionError::Operation("Could not initialize the selected anisette provider.".into())
        })
    }

    async fn build_account(email: &str, anisette_url: &str) -> Result<AppleAccount> {
        let provider = Self::anisette_provider(anisette_url)?;
        timeout(
            AUTH_TIMEOUT,
            AppleAccount::builder(email)
                .danger_debug(false)
                .err_429_retries(Some(2))
                .anisette_provider(provider)
                .build(),
        )
        .await
        .map_err(|_| CompanionError::Operation("Apple authentication timed out.".into()))?
        .map_err(|_| CompanionError::Operation("Could not initialize Apple authentication.".into()))
    }

    async fn developer_session(&self) -> Result<(DeveloperSession, String, String)> {
        if let Some(session) = self.session.lock().await.as_ref().cloned() {
            let email = Self::read_credential(EMAIL_ACCOUNT)?.unwrap_or_default();
            let anisette = Self::read_credential(ANISETTE_URL_ACCOUNT)?.unwrap_or_default();
            return Ok((session, email, anisette));
        }
        let email = Self::read_credential(EMAIL_ACCOUNT)?.ok_or(CompanionError::SigningRequired)?;
        let anisette =
            Self::read_credential(ANISETTE_URL_ACCOUNT)?.ok_or(CompanionError::SigningRequired)?;
        let token = Self::read_credential(TOKEN_ACCOUNT)?.ok_or(CompanionError::SigningRequired)?;
        let adsid = Self::read_credential(ADSID_ACCOUNT)?.ok_or(CompanionError::SigningRequired)?;
        let expiry = Self::read_credential(EXPIRY_ACCOUNT)?
            .and_then(|value| value.parse::<u64>().ok())
            .ok_or(CompanionError::SigningRequired)?;
        if !session_expiry_is_current(expiry, Utc::now().timestamp().max(0) as u64) {
            self.set_state("expired");
            return Err(CompanionError::Operation(
                "Apple session expired. Sign in again.".into(),
            ));
        }
        let account = Self::build_account(&email, &anisette).await?;
        let restored = DeveloperSession::new(
            AppToken {
                token,
                duration: expiry.saturating_sub(Utc::now().timestamp().max(0) as u64),
                expiry,
            },
            adsid,
            account.grandslam_client.clone(),
            account.anisette_generator.clone(),
        );
        *self.session.lock().await = Some(restored.clone());
        self.set_state("authenticated");
        Ok((restored, email, anisette))
    }

    fn current_team_id() -> Result<String> {
        Self::read_credential(TEAM_ACCOUNT)?.ok_or_else(|| {
            CompanionError::Operation("Choose an Apple development team before signing.".into())
        })
    }

    fn device_registered(udid: &str) -> Result<bool> {
        let stored = Self::read_credential(REGISTERED_DEVICES_ACCOUNT)?;
        let values: Vec<String> = match stored {
            Some(value) => serde_json::from_str(&value).map_err(|_| {
                CompanionError::SecureStorage(
                    "The local registered-device list is malformed.".into(),
                )
            })?,
            None => Vec::new(),
        };
        Ok(values.iter().any(|value| value.eq_ignore_ascii_case(udid)))
    }

    fn remember_device(udid: &str) -> Result<()> {
        let stored = Self::read_credential(REGISTERED_DEVICES_ACCOUNT)?;
        let mut values: Vec<String> = match stored {
            Some(value) => serde_json::from_str(&value).map_err(|_| {
                CompanionError::SecureStorage(
                    "The local registered-device list is malformed.".into(),
                )
            })?,
            None => Vec::new(),
        };
        if !values.iter().any(|value| value.eq_ignore_ascii_case(udid)) {
            values.push(udid.to_owned());
        }
        Self::save_credential(REGISTERED_DEVICES_ACCOUNT, &serde_json::to_string(&values)?)
    }

    async fn selected_team(&self, session: &mut DeveloperSession) -> Result<DeveloperTeam> {
        let wanted = Self::current_team_id()?;
        let teams = timeout(APPLE_OPERATION_TIMEOUT, session.list_teams())
            .await
            .map_err(|_| CompanionError::Operation("Apple team lookup timed out.".into()))?
            .map_err(|_| {
                CompanionError::Operation(
                    "Apple team lookup failed. Reauthenticate and try again.".into(),
                )
            })?;
        teams
            .into_iter()
            .find(|team| team.team_id == wanted)
            .ok_or_else(|| {
                CompanionError::Operation(
                    "The selected Apple development team is no longer available.".into(),
                )
            })
    }

    fn signing_storage() -> Box<KeyringStorage> {
        Box::new(KeyringStorage::new(ISIDELOAD_KEYRING_SERVICE.to_owned()))
    }

    fn display_email(value: &str) -> String {
        let Some((local, domain)) = value.split_once('@') else {
            return "Connected Apple Account".into();
        };
        let first = local.chars().next().unwrap_or('*');
        let last = local.chars().last().unwrap_or('*');
        format!("{first}***{last}@{domain}")
    }

    pub fn can_sign_for_device(&self, udid: &str) -> bool {
        let session_valid = AppleAccountProvisioningProvider::status(self).connected;
        let certificate_is_current = Self::read_credential(CERTIFICATE_EXPIRY_ACCOUNT)
            .ok()
            .flatten()
            .and_then(|value| value.parse::<i64>().ok())
            .and_then(|timestamp| DateTime::<Utc>::from_timestamp(timestamp, 0))
            .is_some_and(|expiry| expiry_is_current(expiry, Utc::now()));
        session_valid
            && certificate_is_current
            && Self::read_credential(TEAM_ACCOUNT).ok().flatten().is_some()
            && Self::device_registered(udid).unwrap_or(false)
    }

    async fn sign_verified_package(
        &self,
        package: &ValidatedPackage,
        udid: &str,
    ) -> Result<SignedPackage> {
        if !Self::device_registered(udid)? {
            return Err(CompanionError::Operation(
                "Register this iPhone with the selected Apple team before signing.".into(),
            ));
        }
        let (mut session, email, _) = self.developer_session().await?;
        let team = self.selected_team(&mut session).await?;
        let source_dir = self
            .packages_root
            .join("apple-signing")
            .join(Uuid::new_v4().to_string());
        fs::create_dir_all(&source_dir)?;
        let source_cleanup = ScopedDirectory(source_dir.clone());
        let extracted = source_dir.join("verified-input");
        let validator = PackageValidator;
        validator.extract_for_signing(package, &extracted)?;
        let app_dir = find_single_app_bundle(&extracted)?;
        ensure_supported_package(&app_dir)?;

        type NoCertificateRevocation = fn(
            Vec<isideload::dev::certificates::DevelopmentCertificate>,
        ) -> std::future::Ready<
            std::result::Result<Option<Vec<String>>, rootcause::Report>,
        >;
        let no_revoke: MaxCertsBehavior<NoCertificateRevocation> = MaxCertsBehavior::Error;
        let mut sideloader =
            SideloaderBuilder::<NoCertificateRevocation>::new(session.clone(), email.clone())
                .max_certs_behavior(no_revoke)
                .machine_name(MACHINE_NAME.to_owned())
                .storage(Self::signing_storage())
                .delete_app_after_install(false)
                .build();
        let (signed_temp, special_app) = timeout(
            APPLE_OPERATION_TIMEOUT,
            sideloader.sign_app(app_dir, Some(team.clone()), false, None::<fn(f32) -> std::future::Ready<()>>),
        )
        .await
        .map_err(|_| CompanionError::Operation("Apple provisioning and signing timed out.".into()))?
        .map_err(|_| CompanionError::Operation("Apple provisioning failed. Check team limits, device registration, and app capabilities.".into()))?;
        if special_app.is_some() {
            return Err(CompanionError::Operation(
                "The upstream signer classified this app as a special sideloading app. DreyzeStore does not apply third-party special-app entitlement changes.".into(),
            ));
        }

        let signed_temp = fs::canonicalize(&signed_temp)?;
        let temp_root = fs::canonicalize(std::env::temp_dir())?;
        if !signed_temp.starts_with(&temp_root) || !signed_temp.is_dir() {
            return Err(CompanionError::Operation(
                "The signer returned an unexpected package path.".into(),
            ));
        }
        let signed_root = self.packages_root.join("signed-apple-account");
        fs::create_dir_all(&signed_root)?;
        let final_app = signed_root.join(format!("{}.app", Uuid::new_v4()));
        copy_directory_without_links(&signed_temp, &final_app)?;
        let signed_cleanup = ScopedDirectory(final_app.clone());
        let metadata = inspect_signed_bundle(&final_app)?;
        let effective_bundle =
            deterministic_team_bundle_id(&package.metadata.bundle_identifier, &team.team_id)?;
        if metadata.bundle_identifier != effective_bundle
            || metadata.version != package.metadata.version
            || metadata.build != package.metadata.build
            || metadata.minimum_os_version != package.metadata.minimum_os_version
        {
            return Err(CompanionError::MetadataMismatch);
        }
        let profile_bytes = fs::read(final_app.join("embedded.mobileprovision"))?;
        let profile = super::zsign::parse_mobileprovision(&profile_bytes)?;
        if !profile_authorizes_install(
            &profile,
            &team.team_id,
            &metadata.bundle_identifier,
            udid,
            Utc::now(),
        ) {
            return Err(CompanionError::Operation(
                "Apple returned a provisioning profile that does not authorize this team, app, device, and current date.".into(),
            ));
        }
        let certificate_expiry = Self::read_credential(CERTIFICATE_EXPIRY_ACCOUNT)?
            .and_then(|value| value.parse::<i64>().ok())
            .and_then(|timestamp| DateTime::<Utc>::from_timestamp(timestamp, 0))
            .filter(|expiry| *expiry > Utc::now())
            .ok_or_else(|| {
                CompanionError::Operation(
                    "Prepare a current Apple development certificate before signing this package."
                        .into(),
                )
            })?;
        let signed_sha256 = hash_directory(&final_app)?;
        let info = SignedPackageInfo {
            bundle_identifier: metadata.bundle_identifier,
            version: metadata.version,
            build: metadata.build,
            original_sha256: package.metadata.sha256.clone(),
            signed_sha256,
            signing_identity: "Apple Account local development certificate".into(),
            team_identifier: Some(team.team_id),
            certificate_expires_at: Some(certificate_expiry),
            provisioning_expiration: Some(profile.expiration),
            created_at: Utc::now(),
        };
        // The source extraction is temporary; the signed bundle remains under
        // managed storage until a later cleanup pass.
        drop(source_cleanup);
        signed_cleanup.keep();
        Ok(SignedPackage {
            path: final_app,
            info,
        })
    }
}

#[async_trait]
impl AppleAccountProvisioningProvider for IsideloadAppleAccountProvider {
    async fn authenticate(
        &self,
        app: AppHandle,
        email: String,
        password: Zeroizing<String>,
        anisette_url: String,
        anisette_trust_confirmed: bool,
    ) -> Result<AppleAccountStatus> {
        let email = email.trim().to_ascii_lowercase();
        if email.len() > 254 || !email.contains('@') || password.is_empty() || password.len() > 1024
        {
            return Err(CompanionError::InvalidRequest(
                "Enter a valid Apple Account email and password.".into(),
            ));
        }
        if !anisette_trust_confirmed {
            return Err(CompanionError::InvalidRequest(
                "Confirm that you trust the selected anisette provider before signing in.".into(),
            ));
        }
        let anisette_url = Self::validate_anisette_url(&anisette_url)?;
        self.set_state("authenticating");
        let mut account = Self::build_account(&email, &anisette_url).await?;
        let pending = &self.pending_challenge;
        let app_handle = app.clone();
        let login_result = timeout(
            AUTH_TIMEOUT,
            account.login(password.as_str(), move |params: TwoFactorCallbackParams| {
                let pending = pending;
                let app_handle = app_handle.clone();
                async move {
                    let challenge = TwoFactorChallenge {
                        retry_message: params.last_error.as_ref().map(|_| {
                            "That verification attempt was not accepted. Try again.".into()
                        }),
                        unknown: params.unknown,
                        sms: params.sms,
                        numbers: params
                            .numbers
                            .into_iter()
                            .map(|number| TrustedPhoneOption {
                                id: number.id,
                                last_two_digits: number.last_two_digits,
                            })
                            .collect(),
                        selected_number_id: params.selected_number_id,
                    };
                    let (sender, receiver) = oneshot::channel();
                    *pending.lock().await = Some(sender);
                    let _ = app_handle.emit("apple-account-two-factor", challenge);
                    receiver
                        .await
                        .map_err(|_| rootcause::report!("authentication was cancelled"))
                }
            }),
        )
        .await;
        drop(password);
        match login_result {
            Err(_) => {
                self.set_state("failed");
                return Err(CompanionError::Operation(
                    "Apple Account authentication timed out. Try again.".into(),
                ));
            }
            Ok(Err(_)) => {
                self.set_state("failed");
                return Err(CompanionError::Operation("Apple Account authentication failed or was cancelled. Check the credentials and verification code, then try again.".into()));
            }
            Ok(Ok(())) => {}
        }
        let adsid = account
            .spd
            .as_ref()
            .and_then(|spd| spd.get("adsid"))
            .and_then(plist::Value::as_string)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                CompanionError::Operation(
                    "Apple authentication did not return a developer session.".into(),
                )
            })?
            .to_owned();
        let token = timeout(AUTH_TIMEOUT, account.get_app_token("xcode.auth"))
            .await
            .map_err(|_| {
                CompanionError::Operation("Apple developer session creation timed out.".into())
            })?
            .map_err(|_| {
                CompanionError::Operation("Apple developer session could not be created.".into())
            })?;
        let now = Utc::now().timestamp().max(0) as u64;
        if token.expiry <= now {
            return Err(CompanionError::Operation(
                "Apple returned an expired developer session. Sign in again.".into(),
            ));
        }
        let session = DeveloperSession::new(
            token.clone(),
            adsid.clone(),
            account.grandslam_client.clone(),
            account.anisette_generator.clone(),
        );
        Self::save_credential(EMAIL_ACCOUNT, &email)?;
        Self::save_credential(TOKEN_ACCOUNT, &token.token)?;
        Self::save_credential(ADSID_ACCOUNT, &adsid)?;
        Self::save_credential(EXPIRY_ACCOUNT, &token.expiry.to_string())?;
        Self::save_credential(ANISETTE_URL_ACCOUNT, &anisette_url)?;
        Self::delete_credential(TEAM_ACCOUNT)?;
        Self::delete_credential(REGISTERED_DEVICES_ACCOUNT)?;
        Self::delete_credential(CERTIFICATE_EXPIRY_ACCOUNT)?;
        *self.session.lock().await = Some(session);
        self.set_state("authenticated");
        Ok(AppleAccountProvisioningProvider::status(self))
    }

    async fn submit_two_factor(&self, action: TwoFactorAction) -> Result<()> {
        let response = match action {
            TwoFactorAction::SubmitCode(code) => {
                let code = code.as_str();
                if !(4..=10).contains(&code.len()) || !code.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(CompanionError::InvalidRequest(
                        "Enter the numeric verification code from Apple.".into(),
                    ));
                }
                TwoFactorCallbackResponse::SubmitCode(code.to_owned())
            }
            TwoFactorAction::SendSms(id) => TwoFactorCallbackResponse::SendSms(id),
            TwoFactorAction::SendToDevices => TwoFactorCallbackResponse::SendToDevices,
            TwoFactorAction::ResendCode => TwoFactorCallbackResponse::ResendCode,
            TwoFactorAction::Cancel => TwoFactorCallbackResponse::Abort,
        };
        let sender = self.pending_challenge.lock().await.take().ok_or_else(|| {
            CompanionError::InvalidRequest(
                "There is no active Apple verification challenge.".into(),
            )
        })?;
        sender.send(response).map_err(|_| {
            CompanionError::Operation("The Apple verification request has expired.".into())
        })
    }

    async fn list_teams(&self) -> Result<Vec<AppleTeamSummary>> {
        let (mut session, _, _) = self.developer_session().await?;
        let teams = timeout(APPLE_OPERATION_TIMEOUT, session.list_teams())
            .await
            .map_err(|_| CompanionError::Operation("Apple team lookup timed out.".into()))?
            .map_err(|_| {
                CompanionError::Operation(
                    "Could not load Apple development teams. Reauthenticate and retry.".into(),
                )
            })?;
        *self.session.lock().await = Some(session);
        Ok(teams.into_iter().map(team_summary).collect())
    }

    async fn select_team(&self, team_id: &str) -> Result<AppleAccountStatus> {
        let teams = self.list_teams().await?;
        if !teams.iter().any(|team| team.team_id == team_id) {
            return Err(CompanionError::InvalidRequest(
                "Choose a team returned by Apple for this account.".into(),
            ));
        }
        if Self::read_credential(TEAM_ACCOUNT)?.as_deref() != Some(team_id) {
            Self::delete_credential(REGISTERED_DEVICES_ACCOUNT)?;
            Self::delete_credential(CERTIFICATE_EXPIRY_ACCOUNT)?;
        }
        Self::save_credential(TEAM_ACCOUNT, team_id)?;
        self.set_state("selectingTeam");
        Ok(AppleAccountProvisioningProvider::status(self))
    }

    async fn register_device(
        &self,
        team_id: &str,
        device_name: &str,
        udid: &str,
        explicit_confirmation: bool,
    ) -> Result<()> {
        if !explicit_confirmation {
            return Err(CompanionError::InvalidRequest(
                "Confirm device registration before continuing.".into(),
            ));
        }
        if team_id != Self::current_team_id()?
            || !valid_udid(udid)
            || device_name.trim().is_empty()
            || device_name.len() > 128
        {
            return Err(CompanionError::InvalidRequest(
                "The selected team or connected iPhone identity is invalid.".into(),
            ));
        }
        let (mut session, _, _) = self.developer_session().await?;
        let team = self.selected_team(&mut session).await?;
        timeout(
            APPLE_OPERATION_TIMEOUT,
            session.ensure_device_registered(&team, device_name.trim(), udid, None),
        )
        .await
        .map_err(|_| CompanionError::Operation("Apple device registration timed out.".into()))?
        .map_err(|_| {
            CompanionError::Operation(
                "Apple could not register this iPhone. Check team device limits and try again."
                    .into(),
            )
        })?;
        Self::remember_device(udid)?;
        *self.session.lock().await = Some(session);
        Ok(())
    }

    async fn prepare_signing_certificate(&self, udid: &str) -> Result<chrono::DateTime<Utc>> {
        if !Self::device_registered(udid)? {
            return Err(CompanionError::Operation(
                "Register this iPhone before creating a development certificate.".into(),
            ));
        }
        let (mut session, email, _) = self.developer_session().await?;
        let team = self.selected_team(&mut session).await?;
        let behavior: MaxCertsBehavior<
            fn(
                Vec<isideload::dev::certificates::DevelopmentCertificate>,
            )
                -> std::future::Ready<std::result::Result<Option<Vec<String>>, rootcause::Report>>,
        > = MaxCertsBehavior::Error;
        let identity = timeout(
            APPLE_OPERATION_TIMEOUT,
            isideload::sideload::cert_identity::CertificateIdentity::retrieve(
                MACHINE_NAME,
                &email,
                &mut session,
                &team,
                Self::signing_storage().as_ref(),
                &behavior,
            ),
        )
        .await
        .map_err(|_| CompanionError::Operation("Apple certificate preparation timed out.".into()))?
        .map_err(|_| CompanionError::Operation("Apple could not create a development certificate. Check the team certificate limit; Companion never revokes certificates automatically.".into()))?;
        let expiry = DateTime::<Utc>::from_timestamp(
            identity
                .certificate
                .tbs_certificate
                .validity
                .not_after
                .to_unix_duration()
                .as_secs() as i64,
            0,
        )
        .ok_or_else(|| {
            CompanionError::Operation(
                "Apple returned an invalid certificate expiration date.".into(),
            )
        })?;
        Self::save_credential(CERTIFICATE_EXPIRY_ACCOUNT, &expiry.timestamp().to_string())?;
        *self.session.lock().await = Some(session);
        Ok(expiry)
    }

    fn is_device_registered(&self, udid: &str) -> bool {
        Self::device_registered(udid).unwrap_or(false)
    }

    async fn sign_out(&self) -> Result<()> {
        for key in [
            TOKEN_ACCOUNT,
            ADSID_ACCOUNT,
            EXPIRY_ACCOUNT,
            EMAIL_ACCOUNT,
            ANISETTE_URL_ACCOUNT,
            TEAM_ACCOUNT,
            REGISTERED_DEVICES_ACCOUNT,
            CERTIFICATE_EXPIRY_ACCOUNT,
        ] {
            Self::delete_credential(key)?;
        }
        *self.session.lock().await = None;
        *self.pending_challenge.lock().await = None;
        self.set_state("idle");
        // Intentionally retain the locally generated signing key held in the
        // dedicated isideload keyring. Signing out never revokes Apple assets.
        Ok(())
    }

    fn status(&self) -> AppleAccountStatus {
        let email = Self::read_credential(EMAIL_ACCOUNT).ok().flatten();
        let expiry = Self::read_credential(EXPIRY_ACCOUNT)
            .ok()
            .flatten()
            .and_then(|value| value.parse::<u64>().ok());
        let connected = email.is_some()
            && expiry.is_some_and(|expiry| expiry > Utc::now().timestamp().max(0) as u64);
        let state = if connected {
            "authenticated"
        } else {
            *self
                .auth_state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        };
        AppleAccountStatus {
            connected,
            email: email.map(|value| Self::display_email(&value)),
            selected_team_id: Self::read_credential(TEAM_ACCOUNT).ok().flatten(),
            anisette_url: Self::read_credential(ANISETTE_URL_ACCOUNT).ok().flatten(),
            state,
            limitation: Some("Apple authentication and development provisioning use an unofficial, reverse-engineered protocol. A real Apple account/device test is still required; iOS may reject valid-looking profiles.".into()),
        }
    }
}

impl IsideloadAppleAccountProvider {
    fn delete_credential(name: &str) -> Result<()> {
        WindowsCredentialStore::delete(name)
    }
}

#[async_trait]
impl SigningProvider for IsideloadAppleAccountProvider {
    fn validate_provisioning(&self, package: &ValidatedPackage, target_udid: &str) -> Result<()> {
        if !self.can_sign_for_device(target_udid) {
            return Err(CompanionError::SigningRequired);
        }
        if package.metadata.bundle_identifier.trim().is_empty() {
            return Err(CompanionError::MetadataMismatch);
        }
        Ok(())
    }

    fn validate_device(&self, target_udid: &str) -> Result<()> {
        if self.can_sign_for_device(target_udid) {
            Ok(())
        } else {
            Err(CompanionError::SigningRequired)
        }
    }

    async fn sign(&self, package: &ValidatedPackage, target_udid: &str) -> Result<SignedPackage> {
        self.sign_verified_package(package, target_udid).await
    }

    fn status(&self) -> SigningStatus {
        let apple = AppleAccountProvisioningProvider::status(self);
        let certificate_expiry = Self::read_credential(CERTIFICATE_EXPIRY_ACCOUNT)
            .ok()
            .flatten()
            .and_then(|value| value.parse::<i64>().ok())
            .and_then(|timestamp| DateTime::<Utc>::from_timestamp(timestamp, 0));
        let ready = apple.connected
            && apple.selected_team_id.is_some()
            && certificate_expiry.is_some_and(|expiry| expiry > Utc::now());
        SigningStatus {
            configured: ready,
            identity_label: apple.email,
            certificate_expires_at: certificate_expiry,
            provisioning_expires_at: None,
            team_id: apple.selected_team_id,
            account_kind: Some("Apple Account local provisioning".into()),
            limitation: Some(if ready {
                "Local Apple development identity is ready. App IDs and provisioning profiles are created or reused per app; Personal Team profiles expire and require refresh.".into()
            } else {
                "Sign in, choose a team, register this iPhone, then prepare a local Apple Development certificate.".into()
            }),
        }
    }
}

fn team_summary(team: DeveloperTeam) -> AppleTeamSummary {
    AppleTeamSummary {
        team_id: team.team_id,
        name: team.name.unwrap_or_else(|| "Apple Development Team".into()),
        team_type: team.r#type.unwrap_or_else(|| "Unknown".into()),
    }
}

fn valid_udid(value: &str) -> bool {
    (24..=64).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn session_expiry_is_current(expiry: u64, now: u64) -> bool {
    expiry > now
}

fn expiry_is_current(expiry: DateTime<Utc>, now: DateTime<Utc>) -> bool {
    expiry > now
}

fn profile_authorizes_install(
    profile: &super::zsign::ProvisioningProfile,
    team_id: &str,
    bundle_id: &str,
    udid: &str,
    now: DateTime<Utc>,
) -> bool {
    profile.team_id == team_id
        && profile.authorizes_bundle(bundle_id)
        && profile
            .provisioned_devices
            .iter()
            .any(|device| device.eq_ignore_ascii_case(udid))
        && !profile.developer_certificates.is_empty()
        && expiry_is_current(profile.expiration, now)
}

fn deterministic_team_bundle_id(original: &str, team_id: &str) -> Result<String> {
    let candidate = format!("{original}.{team_id}");
    if candidate.len() > 255 || !valid_bundle_id(&candidate) || team_id.len() != 10 {
        return Err(CompanionError::Operation(
            "This bundle identifier cannot be safely mapped for the selected team.".into(),
        ));
    }
    Ok(candidate)
}

fn valid_bundle_id(value: &str) -> bool {
    let parts = value.split('.').collect::<Vec<_>>();
    parts.len() >= 2
        && parts.iter().all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn find_single_app_bundle(root: &Path) -> Result<PathBuf> {
    let payload = root.join("Payload");
    let entries = fs::read_dir(&payload)?
        .filter_map(std::result::Result::ok)
        .filter(|entry| entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false))
        .filter(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "app")
        })
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    if entries.len() != 1 {
        return Err(CompanionError::InvalidPackage(
            "automatic signing requires one top-level app bundle".into(),
        ));
    }
    Ok(entries[0].clone())
}

fn ensure_supported_package(app: &Path) -> Result<()> {
    // Upstream explicitly says its entitlement and extension handling is TODO.
    // Fail closed until each capability class is verified against profiles.
    if app.join("PlugIns").exists() || app.join("Watch").exists() || app.join("AppClips").exists() {
        return Err(CompanionError::Operation("This package contains extensions or nested apps that automatic signing cannot safely provision yet. Use a reviewed P12/profile or choose a simpler app.".into()));
    }
    let info: plist::Value = plist::from_file(app.join("Info.plist"))
        .map_err(|_| CompanionError::InvalidPackage("app bundle Info.plist is malformed".into()))?;
    let info = info.as_dictionary().ok_or_else(|| {
        CompanionError::InvalidPackage("app bundle Info.plist is not a dictionary".into())
    })?;
    let bundle_id = info
        .get("CFBundleIdentifier")
        .and_then(plist::Value::as_string)
        .ok_or_else(|| {
            CompanionError::InvalidPackage("app bundle has no bundle identifier".into())
        })?;
    let executable = info
        .get("CFBundleExecutable")
        .and_then(plist::Value::as_string)
        .ok_or_else(|| {
            CompanionError::InvalidPackage("app bundle has no executable name".into())
        })?;
    if executable.contains('/')
        || executable.contains('\\')
        || executable == "."
        || executable == ".."
    {
        return Err(CompanionError::InvalidPackage(
            "app executable path is unsafe".into(),
        ));
    }
    let executable_path = app.join(executable);
    if !executable_path.is_file() {
        return Err(CompanionError::InvalidPackage(
            "app executable is missing".into(),
        ));
    }
    inspect_macho_entitlements(app, bundle_id)
}

fn inspect_macho_entitlements(app: &Path, bundle_id: &str) -> Result<()> {
    fn visit(path: &Path, bundle_id: &str) -> Result<()> {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                return Err(CompanionError::InvalidPackage(
                    "automatic signing does not accept app bundle links".into(),
                ));
            }
            if kind.is_dir() {
                visit(&entry.path(), bundle_id)?;
                continue;
            }
            if !kind.is_file() {
                continue;
            }
            let metadata = entry.metadata()?;
            if metadata.len() > 128 * 1024 * 1024 {
                let mut header = [0u8; 4];
                use std::io::Read;
                let mut file = fs::File::open(entry.path())?;
                let read = file.read(&mut header)?;
                if read == 4 && is_macho_or_fat_magic(header) {
                    return Err(CompanionError::Operation(
                        "This app contains a binary too large for safe entitlement inspection."
                            .into(),
                    ));
                }
                continue;
            }
            let data = fs::read(entry.path())?;
            if data.len() < 4 {
                continue;
            }
            let magic = [data[0], data[1], data[2], data[3]];
            if is_fat_magic(magic) {
                return Err(CompanionError::Operation("Universal/fat binaries cannot be safely entitlement-inspected by the current signer.".into()));
            }
            if !is_thin_macho_magic(magic) {
                continue;
            }
            let macho = MachOBinary::parse(&data).map_err(|_| {
                CompanionError::InvalidPackage(
                    "an app Mach-O executable is malformed or unsupported".into(),
                )
            })?;
            let Some(signature) = macho.code_signature().map_err(|_| {
                CompanionError::InvalidPackage("an app code signature is malformed".into())
            })?
            else {
                continue;
            };
            if signature
                .entitlements_der()
                .map_err(|_| {
                    CompanionError::InvalidPackage("DER entitlements could not be inspected".into())
                })?
                .is_some()
            {
                return Err(CompanionError::Operation(
                    "DER-encoded entitlements are not supported by automatic signing yet.".into(),
                ));
            }
            if let Some(entitlements) = signature.entitlements().map_err(|_| {
                CompanionError::InvalidPackage("app entitlements are malformed".into())
            })? {
                let value: plist::Value = plist::from_bytes(entitlements.as_str().as_bytes())
                    .map_err(|_| {
                        CompanionError::InvalidPackage(
                            "app entitlement property list is malformed".into(),
                        )
                    })?;
                validate_entitlements(&value, bundle_id)?;
            }
        }
        Ok(())
    }
    visit(app, bundle_id)
}

fn is_thin_macho_magic(magic: [u8; 4]) -> bool {
    matches!(
        magic,
        [0xcf, 0xfa, 0xed, 0xfe]
            | [0xce, 0xfa, 0xed, 0xfe]
            | [0xfe, 0xed, 0xfa, 0xcf]
            | [0xfe, 0xed, 0xfa, 0xce]
    )
}

fn is_fat_magic(magic: [u8; 4]) -> bool {
    matches!(
        magic,
        [0xca, 0xfe, 0xba, 0xbe]
            | [0xbe, 0xba, 0xfe, 0xca]
            | [0xca, 0xfe, 0xba, 0xbf]
            | [0xbf, 0xba, 0xfe, 0xca]
    )
}

fn is_macho_or_fat_magic(magic: [u8; 4]) -> bool {
    is_thin_macho_magic(magic) || is_fat_magic(magic)
}

fn validate_entitlements(value: &plist::Value, bundle_id: &str) -> Result<()> {
    let entitlements = value.as_dictionary().ok_or_else(|| {
        CompanionError::InvalidPackage("entitlements are not a dictionary".into())
    })?;
    for (key, item) in entitlements {
        match key.as_str() {
            "application-identifier"
            | "com.apple.developer.team-identifier"
            | "get-task-allow"
            | "beta-reports-active" => {}
            "keychain-access-groups" => {
                let groups = item.as_array().ok_or_else(|| {
                    CompanionError::Operation(
                        "The package has an unsupported keychain access-group format.".into(),
                    )
                })?;
                if groups.iter().any(|group| {
                    group.as_string().is_none_or(|group| {
                        group != bundle_id && !group.ends_with(&format!(".{bundle_id}"))
                    })
                }) {
                    return Err(CompanionError::Operation("This package uses a custom keychain access group that cannot be remapped safely for the selected Apple team.".into()));
                }
            }
            _ => {
                return Err(CompanionError::Operation(format!(
                    "Automatic signing does not support the package entitlement `{key}`. Use a compatible app without restricted capabilities."
                )));
            }
        }
    }
    Ok(())
}

fn inspect_signed_bundle(app: &Path) -> Result<PackageMetadata> {
    let info_path = app.join("Info.plist");
    let info: plist::Value = plist::from_file(&info_path)
        .map_err(|_| CompanionError::InvalidPackage("signed app Info.plist is malformed".into()))?;
    let dict = info.as_dictionary().ok_or_else(|| {
        CompanionError::InvalidPackage("signed app Info.plist is not a dictionary".into())
    })?;
    let get = |key: &str| {
        dict.get(key)
            .and_then(plist::Value::as_string)
            .map(ToOwned::to_owned)
    };
    let bundle_identifier =
        get("CFBundleIdentifier").ok_or_else(|| CompanionError::MetadataMismatch)?;
    let version =
        get("CFBundleShortVersionString").ok_or_else(|| CompanionError::MetadataMismatch)?;
    let build = get("CFBundleVersion").ok_or_else(|| CompanionError::MetadataMismatch)?;
    let minimum_os_version = get("MinimumOSVersion");
    let app_name = get("CFBundleDisplayName").or_else(|| get("CFBundleName"));
    if !app.join("embedded.mobileprovision").is_file()
        || !app.join("_CodeSignature/CodeResources").is_file()
    {
        return Err(CompanionError::Operation("The signing engine did not produce a provisioning profile and code-resource signature.".into()));
    }
    let size = directory_size(app)?;
    let sha256 = hash_directory(app)?;
    Ok(PackageMetadata {
        bundle_identifier,
        version,
        build,
        minimum_os_version,
        app_name,
        size,
        sha256,
    })
}

fn directory_size(path: &Path) -> Result<u64> {
    let mut total = 0u64;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            return Err(CompanionError::InvalidPackage(
                "signed app contains a symbolic link".into(),
            ));
        }
        if kind.is_dir() {
            total = total.saturating_add(directory_size(&entry.path())?);
        } else if kind.is_file() {
            total = total.saturating_add(entry.metadata()?.len());
        }
    }
    Ok(total)
}

fn hash_directory(path: &Path) -> Result<String> {
    fn visit(root: &Path, current: &Path, hasher: &mut sha2::Sha256) -> Result<()> {
        let mut entries = fs::read_dir(current)?.collect::<std::io::Result<Vec<_>>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let absolute = entry.path();
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                return Err(CompanionError::InvalidPackage(
                    "signed app contains a symbolic link".into(),
                ));
            }
            let relative = absolute.strip_prefix(root).map_err(|_| {
                CompanionError::InvalidPackage("signed app escaped managed storage".into())
            })?;
            hasher.update(relative.to_string_lossy().replace('\\', "/").as_bytes());
            if kind.is_dir() {
                visit(root, &absolute, hasher)?;
            } else if kind.is_file() {
                hasher.update(fs::read(&absolute)?);
            } else {
                return Err(CompanionError::InvalidPackage(
                    "signed app contains an unsupported filesystem entry".into(),
                ));
            }
        }
        Ok(())
    }
    use sha2::Digest;
    let mut hasher = sha2::Sha256::new();
    visit(path, path, &mut hasher)?;
    Ok(hex::encode(hasher.finalize()))
}

fn copy_directory_without_links(source: &Path, destination: &Path) -> Result<()> {
    if destination.exists() {
        return Err(CompanionError::InvalidRequest(
            "signed package destination already exists".into(),
        ));
    }
    fs::create_dir(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let target = destination.join(entry.file_name());
        if Path::new(&entry.file_name())
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Err(CompanionError::InvalidPackage(
                "signer returned an unsafe path".into(),
            ));
        }
        if kind.is_symlink() {
            return Err(CompanionError::InvalidPackage(
                "signer returned a package containing symbolic links".into(),
            ));
        }
        if kind.is_dir() {
            copy_directory_without_links(&entry.path(), &target)?;
        } else if kind.is_file() {
            fs::copy(entry.path(), target)?;
        } else {
            return Err(CompanionError::InvalidPackage(
                "signer returned an unsupported filesystem entry".into(),
            ));
        }
    }
    Ok(())
}

struct ScopedDirectory(PathBuf);
impl ScopedDirectory {
    fn keep(mut self) {
        self.0.clear();
    }
}
impl Drop for ScopedDirectory {
    fn drop(&mut self) {
        if !self.0.as_os_str().is_empty() {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anisette_url_requires_https_and_rejects_embedded_credentials() {
        assert!(
            IsideloadAppleAccountProvider::validate_anisette_url("http://ani.example").is_err()
        );
        assert!(
            IsideloadAppleAccountProvider::validate_anisette_url("https://user:pass@ani.example")
                .is_err()
        );
        assert!(
            IsideloadAppleAccountProvider::validate_anisette_url(
                "https://ani.example/path?token=x"
            )
            .is_err()
        );
        assert_eq!(
            IsideloadAppleAccountProvider::validate_anisette_url("https://ani.example/").unwrap(),
            "https://ani.example"
        );
    }

    #[test]
    fn personal_team_bundle_mapping_is_deterministic_and_validated() {
        assert_eq!(
            deterministic_team_bundle_id("com.example.app", "ABCDE12345").unwrap(),
            "com.example.app.ABCDE12345"
        );
        assert_eq!(
            deterministic_team_bundle_id("com.example.app", "ABCDE12345").unwrap(),
            deterministic_team_bundle_id("com.example.app", "ABCDE12345").unwrap()
        );
        assert!(deterministic_team_bundle_id("com.example.app", "bad").is_err());
    }

    #[test]
    fn invalid_or_unstable_identifiers_are_rejected() {
        assert!(!valid_udid("not-a-udid"));
        assert!(!valid_bundle_id("com..bad"));
        assert!(valid_bundle_id("com.example.app"));
    }

    #[test]
    fn session_and_certificate_expiration_are_strict() {
        assert!(session_expiry_is_current(101, 100));
        assert!(!session_expiry_is_current(100, 100));
        assert!(expiry_is_current(
            Utc::now() + chrono::Duration::seconds(1),
            Utc::now()
        ));
        assert!(!expiry_is_current(
            Utc::now() - chrono::Duration::seconds(1),
            Utc::now()
        ));
    }

    #[test]
    fn returned_profile_must_match_team_bundle_device_and_expiration() {
        let profile = super::super::zsign::ProvisioningProfile {
            name: "test profile".into(),
            team_id: "ABCDE12345".into(),
            app_identifier: "ABCDE12345.com.example.app.ABCDE12345".into(),
            provisioned_devices: vec!["0123456789abcdef0123456789ABCDEF".into()],
            developer_certificates: vec![vec![1, 2, 3]],
            expiration: Utc::now() + chrono::Duration::days(2),
        };
        let udid = "0123456789abcdef0123456789ABCDEF";
        assert!(profile_authorizes_install(
            &profile,
            "ABCDE12345",
            "com.example.app.ABCDE12345",
            udid,
            Utc::now()
        ));
        assert!(!profile_authorizes_install(
            &profile,
            "OTHER12345",
            "com.example.app.ABCDE12345",
            udid,
            Utc::now()
        ));
        assert!(!profile_authorizes_install(
            &profile,
            "ABCDE12345",
            "com.other.app",
            udid,
            Utc::now()
        ));
        assert!(!profile_authorizes_install(
            &profile,
            "ABCDE12345",
            "com.example.app.ABCDE12345",
            "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
            Utc::now()
        ));
        let mut expired = profile.clone();
        expired.expiration = Utc::now() - chrono::Duration::seconds(1);
        assert!(!profile_authorizes_install(
            &expired,
            "ABCDE12345",
            "com.example.app.ABCDE12345",
            udid,
            Utc::now()
        ));
    }

    #[test]
    fn account_display_redacts_local_part() {
        assert_eq!(
            IsideloadAppleAccountProvider::display_email("farid@example.test"),
            "f***d@example.test"
        );
        assert_eq!(
            IsideloadAppleAccountProvider::display_email("invalid"),
            "Connected Apple Account"
        );
    }

    #[test]
    fn entitlement_allowlist_fails_closed_for_capabilities() {
        let standard: plist::Value = plist::from_bytes(br#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>get-task-allow</key><true/><key>application-identifier</key><string>ABCDE.com.example.app</string></dict></plist>"#).unwrap();
        validate_entitlements(&standard, "com.example.app").unwrap();
        let push: plist::Value = plist::from_bytes(br#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>aps-environment</key><string>development</string></dict></plist>"#).unwrap();
        assert!(validate_entitlements(&push, "com.example.app").is_err());
        let custom_group: plist::Value = plist::from_bytes(br#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>keychain-access-groups</key><array><string>ABCDE.com.example.shared</string></array></dict></plist>"#).unwrap();
        assert!(validate_entitlements(&custom_group, "com.example.app").is_err());
    }
}
