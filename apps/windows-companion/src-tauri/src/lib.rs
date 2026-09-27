mod device;
mod error;
mod installation;
mod models;
mod package;
mod readiness;
mod security;
mod server;
mod signing;

use device::pymobiledevice3::{DeviceProvider, Pymobiledevice3Provider};
use installation::{InstallJobStore, PackageInstallCoordinator};
use models::{
    DeviceInfo, DeviceReadiness, InstallState, PackageExpectation, PackageMetadata, ReadinessCheck,
    ReadinessStatus, SigningStatus,
};
use security::{
    pairing::PairingManager,
    secrets::{SigningIdentityVault, WindowsCredentialStore},
};
use serde::Serialize;
use signing::zsign::SigningProvider;
use std::{path::PathBuf, sync::Arc};
use tauri::{Manager, State};
use tokio::sync::RwLock;
use zeroize::Zeroizing;

#[derive(Clone)]
struct CompanionState {
    data_dir: PathBuf,
    pairing: Arc<PairingManager>,
    devices: Arc<Pymobiledevice3Provider>,
    coordinator: Arc<PackageInstallCoordinator>,
    jobs: InstallJobStore,
    signer: Arc<signing::zsign::AppleDevelopmentSigningProvider>,
    server_info: Arc<RwLock<Option<server::PairingServerInfo>>>,
    server_error: Arc<RwLock<Option<String>>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DashboardSnapshot {
    devices: Vec<DeviceInfo>,
    device_service_available: bool,
    device_service_error: Option<String>,
    signing: SigningStatus,
    paired: bool,
    paired_phone_last_seen_at: Option<chrono::DateTime<chrono::Utc>>,
    local_endpoint: Option<String>,
    api_error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairingQrInfo {
    payload: String,
    code: String,
    endpoint: String,
    certificate_sha256: String,
    expires_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SigningImportResult {
    status: SigningStatus,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InstallHistoryItem {
    bundle_identifier: String,
    version: String,
    build: String,
    udid: String,
    installed_at: chrono::DateTime<chrono::Utc>,
    provisioning_expires_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Clone, Debug, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct TestInstallationRecord {
    bundle_identifier: String,
    version: String,
    build: String,
    sha256: String,
    size: u64,
    udid: String,
    team_identifier: Option<String>,
    certificate_expires_at: Option<chrono::DateTime<chrono::Utc>>,
    provisioning_expires_at: Option<chrono::DateTime<chrono::Utc>>,
    installed_at: chrono::DateTime<chrono::Utc>,
}

#[tauri::command]
async fn get_dashboard_snapshot(
    state: State<'_, CompanionState>,
) -> Result<DashboardSnapshot, String> {
    let (devices, device_service_error) = match state.devices.discover().await {
        Ok(devices) => (devices, None),
        Err(error) => (Vec::new(), Some(error.to_string())),
    };
    let endpoint = state
        .server_info
        .read()
        .await
        .as_ref()
        .map(|info| info.endpoint.clone());
    let api_error = state.server_error.read().await.clone();
    Ok(DashboardSnapshot {
        device_service_available: state.devices.available(),
        devices,
        device_service_error,
        signing: state.signer.status(),
        paired: state.pairing.is_paired(),
        paired_phone_last_seen_at: state.pairing.client_last_seen_at(),
        local_endpoint: endpoint,
        api_error,
    })
}

#[tauri::command]
async fn get_device_readiness(state: State<'_, CompanionState>) -> Result<DeviceReadiness, String> {
    let run_at = chrono::Utc::now();
    let apple_service = apple_mobile_device_service_check();
    let discovery = state.devices.discover().await;
    let (devices, pymobiledevice3) = match discovery {
        Ok(devices) => (
            devices,
            ReadinessCheck {
                status: ReadinessStatus::Pass,
                details: "pymobiledevice3 completed a USB device discovery request.".into(),
            },
        ),
        Err(error) => (
            Vec::new(),
            ReadinessCheck {
                status: ReadinessStatus::Fail,
                details: format!("pymobiledevice3 could not query Apple device services: {error}"),
            },
        ),
    };
    let provisioning = devices.iter().find(|device| device.trusted).map(|device| {
        state
            .signer
            .validate_device(&device.udid)
            .map_err(|error| error.to_string())
    });
    Ok(readiness::build_device_readiness(
        run_at,
        apple_service,
        pymobiledevice3,
        &devices,
        &state.signer.status(),
        provisioning,
        state.pairing.is_paired(),
    ))
}

#[tauri::command]
fn inspect_test_package(path: String) -> Result<PackageMetadata, String> {
    inspect_authorized_test_package(&path).map(|(_, metadata)| metadata)
}

#[tauri::command]
async fn run_test_installation(
    state: State<'_, CompanionState>,
    path: String,
) -> Result<TestInstallationRecord, String> {
    let (path, metadata) = inspect_authorized_test_package(&path)?;
    let device = state
        .devices
        .discover()
        .await
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|device| device.trusted)
        .ok_or_else(|| "Connect and trust an iPhone before testing installation.".to_owned())?;

    let record_path = state.data_dir.join("test-installation.json");
    if read_test_installation(&record_path).await?.is_some() {
        return Err(
            "Uninstall the existing Companion test app before starting another installation test."
                .into(),
        );
    } else if state
        .coordinator
        .inventory(&device.udid)
        .await
        .map_err(|error| error.to_string())?
        .iter()
        .any(|app| app.bundle_identifier == metadata.bundle_identifier)
    {
        return Err(
            "A test app with this bundle ID is already installed but is not managed by the Companion test flow. Remove it on the iPhone first."
                .into(),
        );
    }

    let request_id = uuid::Uuid::new_v4().to_string();
    let expectation = PackageExpectation {
        request_id: request_id.clone(),
        bundle_identifier: metadata.bundle_identifier.clone(),
        version: metadata.version.clone(),
        build: metadata.build.clone(),
        minimum_os_version: metadata.minimum_os_version.clone(),
        sha256: metadata.sha256.clone(),
        size: metadata.size,
        app_name: metadata
            .app_name
            .clone()
            .unwrap_or_else(|| metadata.bundle_identifier.clone()),
    };
    let cancellation = state.jobs.insert(request_id.clone()).ok_or_else(|| {
        "The installation queue is full. Restart Companion after reviewing recent activity."
            .to_owned()
    })?;
    let result = state
        .coordinator
        .execute(path, expectation, device.udid.clone(), cancellation)
        .await;
    let final_state = state.jobs.get(&request_id);
    state.jobs.finish(&request_id);
    result.map_err(|error| error.to_string())?;
    let Some(InstallState::Installed {
        app,
        installed_at,
        signing,
    }) = final_state
    else {
        return Err(
            "The iPhone did not confirm the exact test app version in its inventory.".into(),
        );
    };
    let record = TestInstallationRecord {
        bundle_identifier: app.bundle_identifier,
        version: app.version.unwrap_or_default(),
        build: app.build.unwrap_or_default(),
        sha256: signing.original_sha256,
        size: metadata.size,
        udid: device.udid,
        team_identifier: signing.team_identifier,
        certificate_expires_at: signing.certificate_expires_at,
        provisioning_expires_at: signing.provisioning_expiration,
        installed_at,
    };
    write_test_installation(&record_path, &record).await?;
    Ok(record)
}

#[tauri::command]
async fn get_test_installation(
    state: State<'_, CompanionState>,
) -> Result<Option<TestInstallationRecord>, String> {
    read_test_installation(&state.data_dir.join("test-installation.json")).await
}

#[tauri::command]
async fn uninstall_test_installation(state: State<'_, CompanionState>) -> Result<(), String> {
    let record_path = state.data_dir.join("test-installation.json");
    let record = read_test_installation(&record_path)
        .await?
        .ok_or_else(|| "No Companion-managed test app is recorded.".to_owned())?;
    if !is_authorized_test_bundle(&record.bundle_identifier) {
        return Err("The saved test app record has an invalid bundle identifier.".into());
    }
    state
        .coordinator
        .uninstall(&record.udid, &record.bundle_identifier)
        .await
        .map_err(|error| error.to_string())?;
    tokio::fs::remove_file(record_path)
        .await
        .map_err(|error| error.to_string())
}

fn inspect_authorized_test_package(path: &str) -> Result<(PathBuf, PackageMetadata), String> {
    let source = PathBuf::from(path);
    if source.extension().and_then(|value| value.to_str()) != Some("ipa") {
        return Err("Choose an IPA file for the installation test.".into());
    }
    let canonical = std::fs::canonicalize(&source).map_err(|error| error.to_string())?;
    if !canonical.is_file() {
        return Err("The selected test package is not a regular file.".into());
    }
    let metadata = crate::package::validator::PackageValidator
        .inspect(&canonical)
        .map_err(|error| error.to_string())?;
    if !is_authorized_test_bundle(&metadata.bundle_identifier) {
        return Err(
            "The test install accepts only sample apps with a bundle ID beginning org.dreyzestore.test."
                .into(),
        );
    }
    Ok((canonical, metadata))
}

fn is_authorized_test_bundle(bundle_identifier: &str) -> bool {
    let suffix = bundle_identifier.strip_prefix("org.dreyzestore.test.");
    suffix.is_some_and(|suffix| {
        !suffix.is_empty()
            && suffix.split('.').all(|part| {
                !part.is_empty()
                    && part
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            })
    })
}

async fn read_test_installation(
    path: &std::path::Path,
) -> Result<Option<TestInstallationRecord>, String> {
    match tokio::fs::read(path).await {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| "The saved test installation record is malformed.".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

async fn write_test_installation(
    path: &std::path::Path,
    record: &TestInstallationRecord,
) -> Result<(), String> {
    let bytes = serde_json::to_vec(record).map_err(|error| error.to_string())?;
    let temporary = path.with_extension("new");
    tokio::fs::write(&temporary, bytes)
        .await
        .map_err(|error| error.to_string())?;
    tokio::fs::rename(&temporary, path)
        .await
        .map_err(|error| error.to_string())
}

#[cfg(windows)]
fn apple_mobile_device_service_check() -> ReadinessCheck {
    use windows_sys::Win32::System::Services::{
        CloseServiceHandle, GetServiceKeyNameW, OpenSCManagerW, OpenServiceW, QueryServiceStatusEx,
        SC_MANAGER_CONNECT, SC_STATUS_PROCESS_INFO, SERVICE_QUERY_STATUS, SERVICE_RUNNING,
        SERVICE_STATUS_PROCESS,
    };

    // Resolve the localized display name to the installed service key instead
    // of assuming a fixed internal service name.
    let display_name = "Apple Mobile Device Service\0"
        .encode_utf16()
        .collect::<Vec<_>>();
    // SAFETY: Null names request the local service-control database; the
    // requested access is read-only connection access.
    let manager = unsafe { OpenSCManagerW(std::ptr::null(), std::ptr::null(), SC_MANAGER_CONNECT) };
    if manager.is_null() {
        return failed_apple_service_check();
    }

    let mut service_key = vec![0u16; 256];
    let mut service_key_length = service_key.len() as u32;
    // SAFETY: The SCM handle and NUL-terminated display name are valid, and the
    // output buffer length is provided to the API.
    let found = unsafe {
        GetServiceKeyNameW(
            manager,
            display_name.as_ptr(),
            service_key.as_mut_ptr(),
            &mut service_key_length,
        )
    };
    if found == 0 && service_key_length as usize > service_key.len() && service_key_length <= 1024 {
        service_key.resize(service_key_length as usize, 0);
        let mut retry_length = service_key.len() as u32;
        // SAFETY: Retry with the size reported by the first call.
        let retry = unsafe {
            GetServiceKeyNameW(
                manager,
                display_name.as_ptr(),
                service_key.as_mut_ptr(),
                &mut retry_length,
            )
        };
        if retry == 0 {
            // SAFETY: `manager` was returned by OpenSCManagerW.
            unsafe { CloseServiceHandle(manager) };
            return failed_apple_service_check();
        }
    } else if found == 0 {
        // SAFETY: `manager` was returned by OpenSCManagerW.
        unsafe { CloseServiceHandle(manager) };
        return failed_apple_service_check();
    }

    // SAFETY: `service_key` now contains the service key returned by the SCM.
    let service = unsafe { OpenServiceW(manager, service_key.as_ptr(), SERVICE_QUERY_STATUS) };
    // SAFETY: `manager` was returned by OpenSCManagerW.
    unsafe { CloseServiceHandle(manager) };
    if service.is_null() {
        return failed_apple_service_check();
    }
    let mut service_status = SERVICE_STATUS_PROCESS::default();
    let mut bytes_needed = 0u32;
    // SAFETY: The buffer is correctly sized/aligned for SERVICE_STATUS_PROCESS.
    let queried = unsafe {
        QueryServiceStatusEx(
            service,
            SC_STATUS_PROCESS_INFO,
            (&mut service_status as *mut SERVICE_STATUS_PROCESS).cast(),
            std::mem::size_of::<SERVICE_STATUS_PROCESS>() as u32,
            &mut bytes_needed,
        )
    };
    // SAFETY: `service` was returned by OpenServiceW.
    unsafe { CloseServiceHandle(service) };
    if queried != 0 && service_status.dwCurrentState == SERVICE_RUNNING {
        ReadinessCheck {
            status: ReadinessStatus::Pass,
            details: "Apple Mobile Device Service is running.".into(),
        }
    } else {
        failed_apple_service_check()
    }
}

#[cfg(not(windows))]
fn apple_mobile_device_service_check() -> ReadinessCheck {
    ReadinessCheck {
        status: ReadinessStatus::Unknown,
        details: "Apple Mobile Device Service is only available on Windows.".into(),
    }
}

#[cfg(windows)]
fn failed_apple_service_check() -> ReadinessCheck {
    ReadinessCheck {
        status: ReadinessStatus::Fail,
        details: "Apple Mobile Device Service was not found or is not running. Install classic iTunes from Apple, then restart Companion.".into(),
    }
}

#[tauri::command]
async fn create_pairing_qr(state: State<'_, CompanionState>) -> Result<PairingQrInfo, String> {
    let server = match state.server_info.read().await.clone() {
        Some(server) => server,
        None => {
            return Err(state
                .server_error
                .read()
                .await
                .clone()
                .unwrap_or_else(|| "Local pairing service is still starting.".into()));
        }
    };
    let offer = state.pairing.begin();
    let payload = serde_json::json!({
        "version": 1,
        "endpoint": format!("{}/api/v1", server.endpoint),
        "certificateSHA256": server.certificate_sha256,
        "pairingCode": offer.code,
        "expiresAt": offer.expires_at,
    });
    Ok(PairingQrInfo {
        payload: serde_json::to_string(&payload).map_err(|error| error.to_string())?,
        code: offer.code,
        endpoint: server.endpoint,
        certificate_sha256: server.certificate_sha256,
        expires_at: offer.expires_at,
    })
}

#[tauri::command]
fn forget_paired_phone(state: State<'_, CompanionState>) -> Result<(), String> {
    state.pairing.forget().map_err(|error| error.to_string())
}

#[tauri::command]
fn import_signing_identity(
    state: State<'_, CompanionState>,
    p12_path: String,
    profile_path: String,
    password: String,
) -> Result<SigningImportResult, String> {
    let password = Zeroizing::new(password);
    let vault = SigningIdentityVault::new(state.data_dir.join("signing"));
    let result = vault.import(
        PathBuf::from(p12_path).as_path(),
        PathBuf::from(profile_path).as_path(),
        password.as_str(),
    );
    result.map_err(|error| error.to_string())?;
    Ok(SigningImportResult {
        status: state.signer.status(),
    })
}

#[tauri::command]
fn clear_signing_identity(state: State<'_, CompanionState>) -> Result<(), String> {
    SigningIdentityVault::new(state.data_dir.join("signing"))
        .remove()
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn get_install_history(
    state: State<'_, CompanionState>,
) -> Result<Vec<InstallHistoryItem>, String> {
    let path = state.data_dir.join("install-records.json");
    let bytes = match tokio::fs::read(path).await {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.to_string()),
    };
    let records: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    let values = records
        .as_object()
        .ok_or_else(|| "install history is malformed".to_string())?;
    let mut result = Vec::new();
    for item in values.values() {
        let installed_at = item
            .get("installedAt")
            .and_then(serde_json::Value::as_str)
            .and_then(|date| chrono::DateTime::parse_from_rfc3339(date).ok())
            .map(|date| date.with_timezone(&chrono::Utc));
        if let Some(installed_at) = installed_at {
            result.push(InstallHistoryItem {
                bundle_identifier: item
                    .get("bundleIdentifier")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                version: item
                    .get("version")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                build: item
                    .get("build")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                udid: item
                    .get("udid")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                installed_at,
                provisioning_expires_at: item
                    .get("provisioningExpiresAt")
                    .and_then(serde_json::Value::as_str)
                    .and_then(|date| chrono::DateTime::parse_from_rfc3339(date).ok())
                    .map(|date| date.with_timezone(&chrono::Utc)),
            });
        }
    }
    result.sort_by(|first, second| second.installed_at.cmp(&first.installed_at));
    Ok(result)
}

#[tauri::command]
async fn get_active_install(
    state: State<'_, CompanionState>,
    request_id: String,
) -> Result<Option<InstallState>, String> {
    Ok(state.jobs.get(&request_id))
}

#[cfg(test)]
mod tests {
    use super::is_authorized_test_bundle;

    #[test]
    fn test_installation_accepts_only_scoped_sample_bundle_identifiers() {
        assert!(is_authorized_test_bundle("org.dreyzestore.test.sampleapp"));
        assert!(is_authorized_test_bundle(
            "org.dreyzestore.test.sample-app.ext"
        ));
        assert!(!is_authorized_test_bundle("org.dreyzestore.test"));
        assert!(!is_authorized_test_bundle("org.other.test.sampleapp"));
        assert!(!is_authorized_test_bundle(
            "org.dreyzestore.test..sampleapp"
        ));
        assert!(!is_authorized_test_bundle(
            "org.dreyzestore.test.sample/../../other"
        ));
    }
}

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            get_dashboard_snapshot,
            get_device_readiness,
            inspect_test_package,
            run_test_installation,
            get_test_installation,
            uninstall_test_installation,
            create_pairing_qr,
            forget_paired_phone,
            import_signing_identity,
            clear_signing_identity,
            get_install_history,
            get_active_install,
        ])
        .setup(|app| {
            let data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&data_dir)?;
            let pairing = Arc::new(
                PairingManager::new(Box::new(WindowsCredentialStore))
                    .map_err(|error| std::io::Error::other(error.to_string()))?,
            );
            let devices = Arc::new(Pymobiledevice3Provider::discover_executable());
            let jobs = InstallJobStore::default();
            let vault = SigningIdentityVault::new(data_dir.join("signing"));
            let signer = Arc::new(
                signing::zsign::AppleDevelopmentSigningProvider::from_current_executable(
                    vault,
                    data_dir.join("packages"),
                ),
            );
            let coordinator = Arc::new(PackageInstallCoordinator::new(
                devices.clone(),
                signer.clone(),
                jobs.clone(),
            ));
            let server_info = Arc::new(RwLock::new(None));
            let server_error = Arc::new(RwLock::new(None));
            let state = CompanionState {
                data_dir: data_dir.clone(),
                pairing: pairing.clone(),
                devices: devices.clone(),
                coordinator: coordinator.clone(),
                jobs: jobs.clone(),
                signer: signer.clone(),
                server_info: server_info.clone(),
                server_error: server_error.clone(),
            };
            app.manage(state);
            tauri::async_runtime::spawn(async move {
                match server::start(pairing, devices, coordinator, jobs, signer, data_dir).await {
                    Ok(info) => *server_info.write().await = Some(info),
                    Err(error) => *server_error.write().await = Some(error.to_string()),
                }
            });
            Ok(())
        });
    app.run(tauri::generate_context!())
        .expect("failed to run DreyzeStore Companion");
}
