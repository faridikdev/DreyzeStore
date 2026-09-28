use crate::security::secrets::{WindowsCredentialStore, tls_ip_account, tls_key_account};
use crate::{
    device::pymobiledevice3::DeviceProvider,
    error::{CompanionError, Result},
    installation::{InstallJobStore, PackageInstallCoordinator},
    models::{InstallReceipt, InstallState, PackageExpectation},
    security::pairing::PairingManager,
    signing::zsign::SigningProvider,
};
use axum::{
    Json, Router,
    body::Body,
    extract::{Path as AxumPath, Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::STANDARD_NO_PAD};
use chrono::Utc;
use futures_util::StreamExt;
use rcgen::{CertificateParams, KeyPair};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{io::AsyncWriteExt, net::TcpListener, sync::RwLock, time::timeout};
use uuid::Uuid;

const MAX_UPLOAD_BYTES: u64 = crate::package::validator::MAX_PACKAGE_BYTES;
const MAX_PAIR_ATTEMPTS_PER_WINDOW: usize = 12;
const PAIR_WINDOW: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingServerInfo {
    pub endpoint: String,
    pub certificate_sha256: String,
    pub certificate_der: String,
    pub address: String,
    pub port: u16,
}

#[derive(Clone)]
struct ApiState {
    pairing: Arc<PairingManager>,
    devices: Arc<dyn DeviceProvider>,
    coordinator: Arc<PackageInstallCoordinator>,
    jobs: InstallJobStore,
    signing: Arc<dyn SigningProvider>,
    storage_root: PathBuf,
    pair_attempts: Arc<Mutex<Vec<std::time::Instant>>>,
    records: Arc<RwLock<HashMap<String, InstallRecord>>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallRecord {
    bundle_identifier: String,
    #[serde(default)]
    signed_bundle_identifier: String,
    version: String,
    build: String,
    minimum_os_version: Option<String>,
    app_name: String,
    sha256: String,
    size: u64,
    udid: String,
    original_file: String,
    installed_at: Option<chrono::DateTime<Utc>>,
    provisioning_expires_at: Option<chrono::DateTime<Utc>>,
    #[serde(default)]
    certificate_expires_at: Option<chrono::DateTime<Utc>>,
    #[serde(default)]
    team_identifier: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairRequest {
    code: String,
    client_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairResponse {
    token: String,
    paired_at: chrono::DateTime<Utc>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UninstallRequest {
    udid: String,
    bundle_identifier: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RefreshRequest {
    udid: String,
    bundle_identifier: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum InventorySource {
    CompanionConfirmed,
    LocalRecordOnly,
    Unknown,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct InventoryEntry {
    original_bundle_identifier: Option<String>,
    installed_bundle_identifier: String,
    version: Option<String>,
    build: Option<String>,
    release_sha256: Option<String>,
    team_identifier: Option<String>,
    provision_expiration: Option<chrono::DateTime<Utc>>,
    installed_at: Option<chrono::DateTime<Utc>>,
    device_identifier: String,
    source: InventorySource,
}

#[derive(Deserialize)]
struct InventoryQuery {
    udid: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApiProblem {
    error: String,
}

pub async fn start(
    pairing: Arc<PairingManager>,
    devices: Arc<dyn DeviceProvider>,
    coordinator: Arc<PackageInstallCoordinator>,
    jobs: InstallJobStore,
    signing: Arc<dyn SigningProvider>,
    storage_root: PathBuf,
) -> Result<PairingServerInfo> {
    cleanup_local_package_storage(&storage_root).await;
    let ip = local_ip_address::local_ip().map_err(|error| {
        CompanionError::Operation(format!(
            "could not determine a local network address: {error}"
        ))
    })?;
    if !is_private_unicast(ip) {
        return Err(CompanionError::Operation(
            "no private LAN interface is available for phone pairing".into(),
        ));
    }
    let (cert_pem, key_pem) = load_or_create_local_certificate(&ip, &storage_root)?;
    let cert_der = decode_pem_certificate(&cert_pem)?;
    let cert_hash = hex::encode(Sha256::digest(&cert_der));
    let config = axum_server::tls_rustls::RustlsConfig::from_pem(
        cert_pem.into_bytes(),
        key_pem.into_bytes(),
    )
    .await
    .map_err(|error| {
        CompanionError::Operation(format!("local TLS server could not start: {error}"))
    })?;
    let listener = TcpListener::bind(SocketAddr::new(ip, 0)).await?;
    let address = listener.local_addr()?;
    let std_listener = listener.into_std()?;
    let records = read_records(&storage_root).await;
    let state = ApiState {
        pairing,
        devices,
        coordinator,
        jobs,
        signing,
        storage_root,
        pair_attempts: Arc::new(Mutex::new(Vec::new())),
        records: Arc::new(RwLock::new(records)),
    };
    let app = router(state);
    tokio::spawn(async move {
        axum_server::from_tcp_rustls(std_listener, config)
            .serve(app.into_make_service())
            .await
    });
    Ok(PairingServerInfo {
        endpoint: format!(
            "https://{}:{}",
            match ip {
                IpAddr::V4(value) => value.to_string(),
                IpAddr::V6(value) => format!("[{value}]"),
            },
            address.port()
        ),
        certificate_sha256: cert_hash,
        certificate_der: STANDARD_NO_PAD.encode(cert_der),
        address: ip.to_string(),
        port: address.port(),
    })
}

fn router(state: ApiState) -> Router {
    Router::new()
        .route("/api/v1/pair", post(pair))
        .route("/api/v1/device", get(device))
        .route("/api/v1/signing", get(signing_status))
        .route("/api/v1/install", post(install))
        .route(
            "/api/v1/install/{id}",
            get(install_status).delete(cancel_install),
        )
        .route("/api/v1/apps", get(installed_apps))
        .route("/api/v1/uninstall", post(uninstall))
        .route("/api/v1/refresh", post(refresh))
        .with_state(state)
}

async fn pair(
    State(state): State<ApiState>,
    headers: HeaderMap,
    Json(request): Json<PairRequest>,
) -> Response {
    if !allow_pair_attempt(&state, &headers) {
        return problem(StatusCode::TOO_MANY_REQUESTS, "pairing rate limit exceeded");
    }
    if !Uuid::parse_str(&request.client_id).is_ok_and(|id| id.to_string() == request.client_id) {
        return problem(StatusCode::BAD_REQUEST, "invalid client identifier");
    }
    match state.pairing.complete(&request.code, &request.client_id) {
        Ok(token) => Json(PairResponse {
            token,
            paired_at: Utc::now(),
        })
        .into_response(),
        Err(CompanionError::InvalidPairingCode) => problem(
            StatusCode::UNAUTHORIZED,
            "pairing code is invalid or expired",
        ),
        Err(error) => problem(StatusCode::INTERNAL_SERVER_ERROR, &error.to_string()),
    }
}

async fn device(State(state): State<ApiState>, headers: HeaderMap) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    match state.devices.discover().await {
        Ok(devices) => Json(devices).into_response(),
        Err(error) => problem(StatusCode::SERVICE_UNAVAILABLE, &error.to_string()),
    }
}

async fn signing_status(State(state): State<ApiState>, headers: HeaderMap) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    let mut status = state.signing.status();
    if status.configured {
        match state.devices.discover().await {
            Ok(devices) => match devices.iter().find(|device| device.trusted) {
                Some(device) => {
                    if let Err(error) = state.signing.validate_device(&device.udid) {
                        status.configured = false;
                        status.limitation = Some(error.to_string());
                    }
                }
                None => {
                    status.configured = false;
                    status.limitation = Some(
                        "Connect and trust the target iPhone to verify its provisioning profile."
                            .into(),
                    );
                }
            },
            Err(_) => {
                status.configured = false;
                status.limitation = Some(
                    "The target iPhone could not be checked. Connect it over USB and run diagnostics in Windows Companion.".into(),
                );
            }
        }
    }
    Json(status).into_response()
}

async fn install(State(state): State<ApiState>, headers: HeaderMap, body: Body) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    let metadata = match read_package_expectation(&headers) {
        Ok(value) => value,
        Err(error) => return problem(StatusCode::BAD_REQUEST, &error.to_string()),
    };
    let request_uuid = match Uuid::parse_str(&metadata.request_id) {
        Ok(value) if value.to_string() == metadata.request_id.to_lowercase() => value,
        _ => {
            return problem(
                StatusCode::BAD_REQUEST,
                "requestId must be a canonical UUID",
            );
        }
    };
    let udid = headers
        .get("x-dreyze-udid")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    if !valid_udid(&udid) {
        return problem(
            StatusCode::BAD_REQUEST,
            "a valid target device UDID is required",
        );
    }
    let content_length = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok());
    if content_length != Some(metadata.size)
        || metadata.size == 0
        || metadata.size > MAX_UPLOAD_BYTES
    {
        return problem(
            StatusCode::PAYLOAD_TOO_LARGE,
            "package size is missing, inconsistent, or over the limit",
        );
    }
    if state.jobs.get(&metadata.request_id).is_some() {
        return problem(StatusCode::CONFLICT, "requestId has already been used");
    }
    let staging = state.storage_root.join("staging");
    if let Err(error) = tokio::fs::create_dir_all(&staging).await {
        return problem(StatusCode::INTERNAL_SERVER_ERROR, &error.to_string());
    }
    let path = staging.join(format!("{}.ipa", request_uuid));
    let mut file = match tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .await
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            return problem(StatusCode::CONFLICT, "requestId has already been used");
        }
        Err(error) => return problem(StatusCode::INSUFFICIENT_STORAGE, &error.to_string()),
    };
    let mut stream = body.into_data_stream();
    let mut written = 0u64;
    while let Some(chunk) = timeout(Duration::from_secs(60), stream.next())
        .await
        .ok()
        .flatten()
    {
        let chunk = match chunk {
            Ok(value) => value,
            Err(_) => {
                let _ = tokio::fs::remove_file(&path).await;
                return problem(StatusCode::BAD_REQUEST, "package upload stream failed");
            }
        };
        written = match written.checked_add(chunk.len() as u64) {
            Some(value) if value <= metadata.size && value <= MAX_UPLOAD_BYTES => value,
            _ => {
                let _ = tokio::fs::remove_file(&path).await;
                return problem(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "package exceeded the declared size",
                );
            }
        };
        if let Err(error) = file.write_all(&chunk).await {
            let _ = tokio::fs::remove_file(&path).await;
            return problem(StatusCode::INSUFFICIENT_STORAGE, &error.to_string());
        }
    }
    if written != metadata.size {
        let _ = tokio::fs::remove_file(&path).await;
        return problem(
            StatusCode::BAD_REQUEST,
            "uploaded byte count does not match the release metadata",
        );
    }
    if let Err(error) = file.flush().await {
        let _ = tokio::fs::remove_file(&path).await;
        return problem(StatusCode::INSUFFICIENT_STORAGE, &error.to_string());
    }
    drop(file);
    let Some(cancellation) = state.jobs.insert(metadata.request_id.clone()) else {
        let _ = tokio::fs::remove_file(&path).await;
        return problem(
            StatusCode::TOO_MANY_REQUESTS,
            "too many installation requests are retained; restart the companion after reviewing recent activity",
        );
    };
    let coordinator = state.coordinator.clone();
    let jobs = state.jobs.clone();
    let expected = metadata.clone();
    tokio::spawn(async move {
        if coordinator
            .execute(path.clone(), expected.clone(), udid.clone(), cancellation)
            .await
            .is_ok()
        {
            let installed_state = jobs.get(&expected.request_id);
            let (installed_at, signing_info) = match installed_state {
                Some(InstallState::Installed {
                    installed_at,
                    signing,
                    ..
                }) => (installed_at, signing),
                _ => {
                    let _ = tokio::fs::remove_file(&path).await;
                    jobs.finish(&expected.request_id);
                    return;
                }
            };
            let original_dir = state.storage_root.join("originals");
            if tokio::fs::create_dir_all(&original_dir).await.is_ok() {
                let original_name = format!("{}.ipa", expected.sha256.to_lowercase());
                let original = original_dir.join(&original_name);
                if tokio::fs::rename(&path, &original).await.is_err() && original.is_file() {
                    let _ = tokio::fs::remove_file(path).await;
                }
                let record = InstallRecord {
                    bundle_identifier: expected.bundle_identifier.clone(),
                    signed_bundle_identifier: expected.bundle_identifier.clone(),
                    version: expected.version.clone(),
                    build: expected.build.clone(),
                    minimum_os_version: expected.minimum_os_version.clone(),
                    app_name: expected.app_name.clone(),
                    sha256: expected.sha256.clone(),
                    size: expected.size,
                    udid,
                    original_file: original_name.clone(),
                    installed_at: Some(installed_at),
                    provisioning_expires_at: signing_info.provisioning_expiration,
                    certificate_expires_at: signing_info.certificate_expires_at,
                    team_identifier: signing_info.team_identifier,
                };
                let mut records = state.records.write().await;
                let previous = records
                    .get(&record.bundle_identifier)
                    .map(|item| item.original_file.clone());
                records.insert(record.bundle_identifier.clone(), record);
                let persisted = write_records(&state.storage_root, &records).await.is_ok();
                if persisted
                    && let Some(previous) = previous
                        .filter(|name| name != &original_name && valid_original_filename(name))
                {
                    let _ = tokio::fs::remove_file(original_dir.join(previous)).await;
                }
            }
        } else {
            let _ = tokio::fs::remove_file(&path).await;
        }
        jobs.finish(&expected.request_id);
    });
    (
        StatusCode::ACCEPTED,
        Json(
            serde_json::json!({"requestId": metadata.request_id, "state": InstallState::Received}),
        ),
    )
        .into_response()
}

async fn install_status(
    State(state): State<ApiState>,
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    if Uuid::parse_str(&id).is_err() {
        return problem(StatusCode::BAD_REQUEST, "invalid request id");
    }
    match state.jobs.get(&id) {
        Some(value) => Json(InstallReceipt {
            request_id: id,
            state: value,
        })
        .into_response(),
        None => problem(StatusCode::NOT_FOUND, "installation request was not found"),
    }
}

async fn cancel_install(
    State(state): State<ApiState>,
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    if state.jobs.cancel(&id) {
        (
            StatusCode::ACCEPTED,
            Json(serde_json::json!({"requestId": id, "state": "cancelling"})),
        )
            .into_response()
    } else {
        problem(
            StatusCode::NOT_FOUND,
            "active installation request was not found",
        )
    }
}

async fn installed_apps(
    State(state): State<ApiState>,
    Query(query): Query<InventoryQuery>,
    headers: HeaderMap,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    if query.udid.len() < 24
        || query.udid.len() > 64
        || !query
            .udid
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return problem(StatusCode::BAD_REQUEST, "invalid device UDID");
    }
    match state.coordinator.inventory(&query.udid).await {
        Ok(apps) => {
            let records = state.records.read().await;
            let entries = map_inventory_entries(apps, &records, &query.udid);
            Json(entries).into_response()
        }
        Err(error) => problem(StatusCode::SERVICE_UNAVAILABLE, &error.to_string()),
    }
}

fn map_inventory_entries(
    apps: Vec<crate::models::InstalledApp>,
    records: &HashMap<String, InstallRecord>,
    udid: &str,
) -> Vec<InventoryEntry> {
    let device_identifier = hex::encode(Sha256::digest(udid.to_ascii_lowercase().as_bytes()));
    apps.into_iter()
        .map(|app| {
            let matched = records.values().find(|record| {
                record.udid.eq_ignore_ascii_case(udid)
                    && record
                        .signed_bundle_identifier
                        .eq_ignore_ascii_case(&app.bundle_identifier)
            });
            let source = matched
                .map(|record| {
                    if app.version.as_deref() == Some(record.version.as_str())
                        && app.build.as_deref() == Some(record.build.as_str())
                    {
                        InventorySource::CompanionConfirmed
                    } else {
                        InventorySource::LocalRecordOnly
                    }
                })
                .unwrap_or(InventorySource::Unknown);
            let confirmed = (source == InventorySource::CompanionConfirmed)
                .then_some(matched)
                .flatten();
            InventoryEntry {
                original_bundle_identifier: matched.map(|record| record.bundle_identifier.clone()),
                installed_bundle_identifier: app.bundle_identifier,
                version: app.version,
                build: app.build,
                release_sha256: confirmed.map(|record| record.sha256.clone()),
                team_identifier: confirmed.and_then(|record| record.team_identifier.clone()),
                provision_expiration: confirmed
                    .and_then(|record| record.provisioning_expires_at.clone()),
                installed_at: confirmed.and_then(|record| record.installed_at.clone()),
                device_identifier: device_identifier.clone(),
                source,
            }
        })
        .collect()
}

async fn uninstall(
    State(state): State<ApiState>,
    headers: HeaderMap,
    Json(request): Json<UninstallRequest>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    match state
        .coordinator
        .uninstall(&request.udid, &request.bundle_identifier)
        .await
    {
        Ok(()) => {
            let mut records = state.records.write().await;
            let removed = records.remove(&request.bundle_identifier);
            let persisted = write_records(&state.storage_root, &records).await.is_ok();
            if persisted
                && let Some(record) = removed
                    .filter(|record| safe_original_filename(&record.original_file, &record.sha256))
            {
                let _ = tokio::fs::remove_file(
                    state
                        .storage_root
                        .join("originals")
                        .join(record.original_file),
                )
                .await;
            }
            Json(serde_json::json!({"result": "uninstalled"})).into_response()
        }
        Err(error) => problem(StatusCode::CONFLICT, &error.to_string()),
    }
}

async fn refresh(
    State(state): State<ApiState>,
    headers: HeaderMap,
    Json(request): Json<RefreshRequest>,
) -> Response {
    if let Err(response) = authorize(&state, &headers) {
        return response;
    }
    let record = state
        .records
        .read()
        .await
        .get(&request.bundle_identifier)
        .cloned();
    let Some(record) = record else {
        return problem(
            StatusCode::NOT_FOUND,
            "no DreyzeStore-managed source package is available to refresh this app",
        );
    };
    if !record.udid.eq_ignore_ascii_case(&request.udid) {
        return problem(
            StatusCode::FORBIDDEN,
            "the saved package is paired to another device",
        );
    }
    let request_id = Uuid::new_v4().to_string();
    let expected = PackageExpectation {
        request_id: request_id.clone(),
        bundle_identifier: record.bundle_identifier.clone(),
        version: record.version.clone(),
        build: record.build.clone(),
        minimum_os_version: record.minimum_os_version.clone(),
        sha256: record.sha256.clone(),
        size: record.size,
        app_name: record.app_name.clone(),
    };
    if !valid_bundle_identifier(&record.bundle_identifier)
        || !safe_original_filename(&record.original_file, &record.sha256)
    {
        return problem(
            StatusCode::INTERNAL_SERVER_ERROR,
            "saved package reference is invalid",
        );
    }
    let original = state
        .storage_root
        .join("originals")
        .join(&record.original_file);
    if !original.is_file() {
        return problem(
            StatusCode::NOT_FOUND,
            "saved original package is no longer available",
        );
    }
    let Some(cancellation) = state.jobs.insert(request_id.clone()) else {
        return problem(
            StatusCode::TOO_MANY_REQUESTS,
            "too many installation requests are retained",
        );
    };
    let coordinator = state.coordinator.clone();
    let jobs = state.jobs.clone();
    let original_file = original.clone();
    let expected_for_run = expected.clone();
    let udid = record.udid.clone();
    tokio::spawn(async move {
        if coordinator
            .execute(original_file, expected_for_run.clone(), udid, cancellation)
            .await
            .is_ok()
        {
            if let Some(InstallState::Installed {
                installed_at,
                signing,
                ..
            }) = jobs.get(&expected_for_run.request_id)
            {
                let mut records = state.records.write().await;
                if let Some(current) = records.get_mut(&expected_for_run.bundle_identifier) {
                    current.installed_at = Some(installed_at);
                    current.provisioning_expires_at = signing.provisioning_expiration;
                    current.certificate_expires_at = signing.certificate_expires_at;
                    current.team_identifier = signing.team_identifier;
                    current.signed_bundle_identifier = signing.bundle_identifier;
                    let _ = write_records(&state.storage_root, &records).await;
                }
            }
        }
        jobs.finish(&expected_for_run.request_id);
    });
    (
        StatusCode::ACCEPTED,
        Json(serde_json::json!({"requestId": request_id, "state": InstallState::Received})),
    )
        .into_response()
}

fn read_package_expectation(headers: &HeaderMap) -> Result<PackageExpectation> {
    let raw = headers
        .get("x-dreyze-package")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| {
            CompanionError::InvalidRequest("X-Dreyze-Package metadata header is required".into())
        })?;
    if raw.len() > 8192 {
        return Err(CompanionError::InvalidRequest(
            "package metadata header is too large".into(),
        ));
    }
    let bytes = STANDARD_NO_PAD
        .decode(raw)
        .map_err(|_| CompanionError::InvalidRequest("invalid package metadata encoding".into()))?;
    serde_json::from_slice(&bytes)
        .map_err(|_| CompanionError::InvalidRequest("package metadata JSON is invalid".into()))
}

fn authorize(state: &ApiState, headers: &HeaderMap) -> std::result::Result<(), Response> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .ok_or_else(|| {
            problem(
                StatusCode::UNAUTHORIZED,
                "pairing authorization is required",
            )
        })?;
    let client_id = headers
        .get("x-dreyze-client-id")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| {
            problem(
                StatusCode::UNAUTHORIZED,
                "paired client identifier is required",
            )
        })?;
    let timestamp = headers
        .get("x-dreyze-timestamp")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<i64>().ok())
        .ok_or_else(|| problem(StatusCode::UNAUTHORIZED, "request timestamp is required"))?;
    let nonce = headers
        .get("x-dreyze-nonce")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| problem(StatusCode::UNAUTHORIZED, "request nonce is required"))?;
    state
        .pairing
        .authenticate(token, client_id, nonce, timestamp)
        .map_err(|error| {
            let status = match error {
                CompanionError::PairingRequired
                | CompanionError::AuthenticationFailed
                | CompanionError::ReplayRejected => StatusCode::UNAUTHORIZED,
                _ => StatusCode::UNAUTHORIZED,
            };
            problem(status, &error.to_string())
        })
}

fn allow_pair_attempt(state: &ApiState, headers: &HeaderMap) -> bool {
    let mut attempts = state
        .pair_attempts
        .lock()
        .expect("pair attempts mutex poisoned");
    let now = std::time::Instant::now();
    attempts.retain(|time| now.duration_since(*time) < PAIR_WINDOW);
    if attempts.len() >= MAX_PAIR_ATTEMPTS_PER_WINDOW {
        return false;
    }
    attempts.push(now);
    let _ = headers;
    true
}

fn valid_udid(udid: &str) -> bool {
    udid.len() >= 24
        && udid.len() <= 64
        && udid
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
}

fn valid_bundle_identifier(value: &str) -> bool {
    let parts: Vec<_> = value.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn safe_original_filename(filename: &str, sha256: &str) -> bool {
    sha256.len() == 64
        && sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        && filename.eq_ignore_ascii_case(&format!("{}.ipa", sha256.to_ascii_lowercase()))
}

fn valid_original_filename(filename: &str) -> bool {
    filename
        .strip_suffix(".ipa")
        .is_some_and(|sha| safe_original_filename(filename, sha))
}

fn load_or_create_local_certificate(ip: &IpAddr, storage_root: &Path) -> Result<(String, String)> {
    let cert_path = storage_root.join("local-api-cert.pem");
    let stored_ip = WindowsCredentialStore::get(tls_ip_account())?;
    let stored_key = WindowsCredentialStore::get(tls_key_account())?;
    if stored_ip.as_deref() == Some(&ip.to_string()) {
        if let (Ok(certificate), Some(key)) = (std::fs::read_to_string(&cert_path), stored_key) {
            if decode_pem_certificate(&certificate).is_ok() {
                return Ok((certificate, key));
            }
        }
    }
    std::fs::create_dir_all(storage_root)?;
    let mut params = CertificateParams::new(vec![ip.to_string()]).map_err(|error| {
        CompanionError::Operation(format!(
            "local TLS certificate could not be created: {error}"
        ))
    })?;
    params.not_before = time::OffsetDateTime::now_utc() - time::Duration::days(1);
    params.not_after = time::OffsetDateTime::now_utc() + time::Duration::days(365);
    let key = KeyPair::generate().map_err(|error| {
        CompanionError::Operation(format!("local TLS key generation failed: {error}"))
    })?;
    let certificate = params.self_signed(&key).map_err(|error| {
        CompanionError::Operation(format!("local TLS certificate signing failed: {error}"))
    })?;
    let cert_pem = certificate.pem();
    let key_pem = key.serialize_pem();
    std::fs::write(cert_path, &cert_pem)?;
    WindowsCredentialStore::set(tls_key_account(), &key_pem)?;
    WindowsCredentialStore::set(tls_ip_account(), &ip.to_string())?;
    Ok((cert_pem, key_pem))
}

fn decode_pem_certificate(pem: &str) -> Result<Vec<u8>> {
    let start = pem
        .find("-----BEGIN CERTIFICATE-----")
        .ok_or_else(|| CompanionError::Operation("stored TLS certificate is malformed".into()))?
        + "-----BEGIN CERTIFICATE-----".len();
    let end = pem
        .find("-----END CERTIFICATE-----")
        .ok_or_else(|| CompanionError::Operation("stored TLS certificate is malformed".into()))?;
    base64::engine::general_purpose::STANDARD
        .decode(
            pem[start..end]
                .chars()
                .filter(|character| !character.is_whitespace())
                .collect::<String>(),
        )
        .map_err(|_| CompanionError::Operation("stored TLS certificate is malformed".into()))
}

fn problem(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(ApiProblem {
            error: message.to_owned(),
        }),
    )
        .into_response()
}

fn is_private_unicast(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(value) => {
            value.is_private()
                && !value.is_loopback()
                && !value.is_unspecified()
                && !value.is_link_local()
        }
        IpAddr::V6(value) => value.is_unique_local(),
    }
}

async fn read_records(storage_root: &Path) -> HashMap<String, InstallRecord> {
    let path = storage_root.join("install-records.json");
    let Ok(bytes) = tokio::fs::read(path).await else {
        return HashMap::new();
    };
    serde_json::from_slice(&bytes).unwrap_or_default()
}

async fn cleanup_local_package_storage(storage_root: &Path) {
    let records = read_records(storage_root).await;
    let referenced: std::collections::HashSet<String> = records
        .values()
        .filter(|record| safe_original_filename(&record.original_file, &record.sha256))
        .map(|record| record.original_file.clone())
        .collect();
    for directory in [
        storage_root.join("staging"),
        storage_root.join("packages").join("signed"),
    ] {
        let Ok(mut entries) = tokio::fs::read_dir(&directory).await else {
            continue;
        };
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if entry.file_type().await.is_ok_and(|kind| kind.is_file()) {
                let _ = tokio::fs::remove_file(path).await;
            }
        }
    }
    let package_root = storage_root.join("packages");
    if let Ok(mut entries) = tokio::fs::read_dir(&package_root).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name != "signed"
                && Uuid::parse_str(&name).is_ok()
                && entry.file_type().await.is_ok_and(|kind| kind.is_dir())
            {
                let _ = tokio::fs::remove_dir_all(entry.path()).await;
            }
        }
    }
    if let Ok(mut entries) = tokio::fs::read_dir(storage_root).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name
                .strip_prefix("install-records-")
                .and_then(|value| value.strip_suffix(".new"))
                .is_some_and(|value| Uuid::parse_str(value).is_ok())
                && entry.file_type().await.is_ok_and(|kind| kind.is_file())
            {
                let _ = tokio::fs::remove_file(entry.path()).await;
            }
        }
    }
    let originals = storage_root.join("originals");
    let Ok(mut entries) = tokio::fs::read_dir(&originals).await else {
        return;
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = entry.file_name().to_string_lossy().into_owned();
        if valid_original_filename(&name) && !referenced.contains(&name) {
            let _ = tokio::fs::remove_file(entry.path()).await;
        }
    }
}

async fn write_records(
    storage_root: &Path,
    records: &HashMap<String, InstallRecord>,
) -> Result<()> {
    let bytes = serde_json::to_vec(records)?;
    let path = storage_root.join("install-records.json");
    let temporary = storage_root.join(format!("install-records-{}.new", Uuid::new_v4()));
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .await?;
    file.write_all(&bytes).await?;
    file.flush().await?;
    file.sync_all().await?;
    drop(file);
    if let Err(error) = tokio::fs::rename(&temporary, &path).await {
        let _ = tokio::fs::remove_file(temporary).await;
        return Err(error.into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        device::pymobiledevice3::Pymobiledevice3Provider,
        installation::PackageInstallCoordinator,
        security::{
            pairing::{PairingManager, PairingSecretStore},
            secrets::SigningIdentityVault,
        },
        signing::zsign::AppleDevelopmentSigningProvider,
    };
    use http::HeaderValue;

    #[derive(Default)]
    struct TestSecrets(Mutex<Option<String>>);
    impl PairingSecretStore for TestSecrets {
        fn load_token_hash(&self) -> Result<Option<String>> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn save_token_hash(&self, value: &str) -> Result<()> {
            *self.0.lock().unwrap() = Some(value.to_owned());
            Ok(())
        }
        fn clear_token_hash(&self) -> Result<()> {
            *self.0.lock().unwrap() = None;
            Ok(())
        }
    }

    fn api_state(storage_root: PathBuf) -> (ApiState, String, String) {
        let pairing = Arc::new(PairingManager::new(Box::new(TestSecrets::default())).unwrap());
        let offer = pairing.begin();
        let client_id = "01234567-89ab-cdef-0123-456789abcdef".to_owned();
        let token = pairing.complete(&offer.code, &client_id).unwrap();
        let devices = Arc::new(Pymobiledevice3Provider::discover_executable());
        let jobs = InstallJobStore::default();
        let signer = Arc::new(AppleDevelopmentSigningProvider::new(
            PathBuf::from("missing-zsign.exe"),
            SigningIdentityVault::new(storage_root.join("signing")),
            storage_root.join("packages"),
        ));
        let coordinator = Arc::new(PackageInstallCoordinator::new(
            devices.clone(),
            signer.clone(),
            jobs.clone(),
        ));
        let state = ApiState {
            pairing,
            devices,
            coordinator,
            jobs,
            signing: signer,
            storage_root,
            pair_attempts: Arc::new(Mutex::new(Vec::new())),
            records: Arc::new(RwLock::new(HashMap::new())),
        };
        (state, token, client_id)
    }

    fn authenticated_headers(token: &str, client_id: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        headers.insert(
            "x-dreyze-client-id",
            HeaderValue::from_str(client_id).unwrap(),
        );
        headers.insert(
            "x-dreyze-timestamp",
            Utc::now().timestamp().to_string().parse().unwrap(),
        );
        headers.insert(
            "x-dreyze-nonce",
            Uuid::new_v4().to_string().parse().unwrap(),
        );
        headers
    }

    fn companion_record(udid: &str) -> InstallRecord {
        InstallRecord {
            bundle_identifier: "com.example.original".into(),
            signed_bundle_identifier: "com.example.signed".into(),
            version: "2.0".into(),
            build: "200".into(),
            minimum_os_version: Some("16.0".into()),
            app_name: "Example".into(),
            sha256: "a".repeat(64),
            size: 123,
            udid: udid.into(),
            original_file: format!("{}.ipa", "a".repeat(64)),
            installed_at: Some(Utc::now()),
            provisioning_expires_at: Some(Utc::now() + chrono::Duration::days(10)),
            certificate_expires_at: None,
            team_identifier: Some("TEAM123".into()),
        }
    }

    #[test]
    fn inventory_marks_only_exact_device_version_and_build_as_companion_confirmed() {
        let udid = "00000000-000000000000000000000001";
        let mut records = HashMap::new();
        records.insert("com.example.original".into(), companion_record(udid));
        let apps = vec![
            crate::models::InstalledApp {
                bundle_identifier: "com.example.signed".into(),
                version: Some("2.0".into()),
                build: Some("200".into()),
            },
            crate::models::InstalledApp {
                bundle_identifier: "com.example.signed".into(),
                version: Some("1.0".into()),
                build: Some("100".into()),
            },
            crate::models::InstalledApp {
                bundle_identifier: "com.example.untracked".into(),
                version: Some("1.0".into()),
                build: Some("1".into()),
            },
        ];

        let mapped = map_inventory_entries(apps, &records, udid);

        assert_eq!(mapped[0].source, InventorySource::CompanionConfirmed);
        assert_eq!(
            mapped[0].original_bundle_identifier.as_deref(),
            Some("com.example.original")
        );
        assert_eq!(
            mapped[0].release_sha256.as_deref(),
            Some("a".repeat(64).as_str())
        );
        assert_eq!(mapped[1].source, InventorySource::LocalRecordOnly);
        assert!(mapped[1].release_sha256.is_none());
        assert_eq!(mapped[2].source, InventorySource::Unknown);
        assert!(mapped[2].original_bundle_identifier.is_none());
        assert_ne!(mapped[0].device_identifier, udid);
        let json = serde_json::to_value(&mapped[0]).unwrap();
        assert_eq!(json["source"], "companionConfirmed");
        assert!(json.get("udid").is_none());
    }

    #[test]
    fn metadata_header_requires_bounded_base64_json() {
        let mut headers = HeaderMap::new();
        assert!(read_package_expectation(&headers).is_err());
        headers.insert("x-dreyze-package", "not base64".parse().unwrap());
        assert!(read_package_expectation(&headers).is_err());
    }

    #[test]
    fn certificate_network_binding_rejects_public_or_wildcard_addresses() {
        assert!(is_private_unicast("192.168.1.20".parse().unwrap()));
        assert!(is_private_unicast("10.10.0.2".parse().unwrap()));
        assert!(!is_private_unicast("8.8.8.8".parse().unwrap()));
        assert!(!is_private_unicast("0.0.0.0".parse().unwrap()));
    }

    #[tokio::test]
    async fn cleanup_removes_orphaned_temporary_files_and_only_safe_unreferenced_originals() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let staging = root.join("staging");
        let packages = root.join("packages");
        let signed = packages.join("signed");
        let originals = root.join("originals");
        tokio::fs::create_dir_all(&staging).await.unwrap();
        tokio::fs::create_dir_all(&signed).await.unwrap();
        tokio::fs::create_dir_all(&originals).await.unwrap();
        let stale_job = packages.join(Uuid::new_v4().to_string());
        tokio::fs::create_dir_all(&stale_job).await.unwrap();
        tokio::fs::write(staging.join("stale.ipa"), b"staging")
            .await
            .unwrap();
        tokio::fs::write(signed.join("stale.ipa"), b"signed")
            .await
            .unwrap();
        tokio::fs::write(stale_job.join("signing-identity.p12"), b"secret material")
            .await
            .unwrap();
        let used_digest = "a".repeat(64);
        let unused_digest = "b".repeat(64);
        tokio::fs::write(originals.join(format!("{used_digest}.ipa")), b"used")
            .await
            .unwrap();
        tokio::fs::write(originals.join(format!("{unused_digest}.ipa")), b"orphan")
            .await
            .unwrap();
        tokio::fs::write(originals.join("not-a-digest.ipa"), b"unsafe name")
            .await
            .unwrap();
        let record = InstallRecord {
            bundle_identifier: "org.example.app".into(),
            signed_bundle_identifier: "org.example.app".into(),
            version: "1.0".into(),
            build: "1".into(),
            minimum_os_version: Some("16.0".into()),
            app_name: "Sample".into(),
            sha256: used_digest.clone(),
            size: 4,
            udid: "0123456789abcdef0123456789abcdef".into(),
            original_file: format!("{used_digest}.ipa"),
            installed_at: None,
            provisioning_expires_at: None,
            certificate_expires_at: None,
            team_identifier: None,
        };
        let records = HashMap::from([(record.bundle_identifier.clone(), record)]);
        tokio::fs::write(
            root.join("install-records.json"),
            serde_json::to_vec(&records).unwrap(),
        )
        .await
        .unwrap();

        cleanup_local_package_storage(root).await;

        assert!(!staging.join("stale.ipa").exists());
        assert!(!signed.join("stale.ipa").exists());
        assert!(!stale_job.exists());
        assert!(originals.join(format!("{used_digest}.ipa")).exists());
        assert!(!originals.join(format!("{unused_digest}.ipa")).exists());
        assert!(originals.join("not-a-digest.ipa").exists());
        assert!(!valid_original_filename("../outside.ipa"));
    }

    #[tokio::test]
    async fn unauthenticated_device_request_is_rejected_before_device_access() {
        let directory = tempfile::tempdir().unwrap();
        let (state, _, _) = api_state(directory.path().to_owned());
        let response = device(State(state), HeaderMap::new()).await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn refresh_without_a_companion_managed_release_is_not_found() {
        let directory = tempfile::tempdir().unwrap();
        let (state, token, client_id) = api_state(directory.path().to_owned());
        let response = refresh(
            State(state),
            authenticated_headers(&token, &client_id),
            Json(RefreshRequest {
                udid: "0123456789abcdef0123456789ABCDEF".into(),
                bundle_identifier: "org.example.app".into(),
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn tls_certificate_pem_is_decoded_for_exact_sha256_pin() {
        let der = vec![0x30, 0x03, 0x02, 0x01, 0x00];
        let pem = format!(
            "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n",
            base64::engine::general_purpose::STANDARD.encode(der)
        );
        assert_eq!(
            decode_pem_certificate(&pem).unwrap(),
            vec![0x30, 0x03, 0x02, 0x01, 0x00]
        );
    }
}
