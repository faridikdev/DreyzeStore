mod device;
mod error;
mod installation;
mod models;
mod package;
mod security;
mod server;
mod signing;

use device::pymobiledevice3::{DeviceProvider, Pymobiledevice3Provider};
use installation::{InstallJobStore, PackageInstallCoordinator};
use models::{DeviceInfo, InstallState, SigningStatus};
use security::{
    pairing::PairingManager,
    secrets::{SigningIdentityVault, WindowsCredentialStore},
};
use serde::Serialize;
use signing::zsign::SigningProvider;
use std::{path::PathBuf, sync::Arc};
use tauri::{Manager, State};
use tokio::sync::RwLock;
use zeroize::Zeroize;

#[derive(Clone)]
struct CompanionState {
    data_dir: PathBuf,
    pairing: Arc<PairingManager>,
    devices: Arc<Pymobiledevice3Provider>,
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
    mut password: String,
) -> Result<SigningImportResult, String> {
    let vault = SigningIdentityVault::new(state.data_dir.join("signing"));
    let result = vault.import(
        PathBuf::from(p12_path).as_path(),
        PathBuf::from(profile_path).as_path(),
        &password,
    );
    password.zeroize();
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

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            get_dashboard_snapshot,
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
