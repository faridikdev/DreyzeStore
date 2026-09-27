use crate::{
    error::{CompanionError, Result},
    models::{DeviceInfo, InstalledApp},
};
use async_trait::async_trait;
use serde_json::Value;
use std::{
    path::PathBuf,
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{process::Command, time::timeout};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(180);
const MAX_STDOUT_BYTES: usize = 16 * 1024 * 1024;

#[async_trait]
pub trait DeviceProvider: Send + Sync {
    async fn discover(&self) -> Result<Vec<DeviceInfo>>;
    async fn installed_apps(&self, udid: &str) -> Result<Vec<InstalledApp>>;
    async fn install(&self, udid: &str, package: &std::path::Path) -> Result<()>;
    async fn uninstall(&self, udid: &str, bundle_identifier: &str) -> Result<()>;
}

#[derive(Clone, Debug)]
enum CommandSpec {
    Executable(PathBuf),
    PythonModule(PathBuf),
}

#[derive(Clone, Debug)]
pub struct Pymobiledevice3Provider {
    command: Option<CommandSpec>,
    available: Arc<AtomicBool>,
}

impl Pymobiledevice3Provider {
    pub fn discover_executable() -> Self {
        let sidecar = std::env::current_exe().ok().and_then(|path| {
            path.parent()
                .map(|parent| parent.join("pymobiledevice3-x86_64-pc-windows-msvc.exe"))
        });
        let command = sidecar
            .filter(|path| path.is_file())
            .map(CommandSpec::Executable)
            .or_else(|| {
                find_on_path(&["pymobiledevice3.exe", "pymobiledevice3"])
                    .map(CommandSpec::Executable)
            })
            .or_else(|| {
                find_on_path(&["py.exe", "python.exe", "python"]).map(CommandSpec::PythonModule)
            });
        Self {
            command,
            available: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn available(&self) -> bool {
        self.available.load(Ordering::Relaxed)
    }

    async fn run(&self, args: &[String]) -> Result<Vec<u8>> {
        let command = self.command.as_ref().ok_or_else(|| CompanionError::DeviceServiceUnavailable(
            "Install the classic iTunes for Windows package and pymobiledevice3, then restart Companion.".into()
        ))?;
        let (program, prefix) = match command {
            CommandSpec::Executable(path) => (path.clone(), Vec::<String>::new()),
            CommandSpec::PythonModule(path) => {
                (path.clone(), vec!["-m".into(), "pymobiledevice3".into()])
            }
        };
        let mut child = Command::new(program);
        child
            .args(prefix)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let output = timeout(COMMAND_TIMEOUT, child.output())
            .await
            .map_err(|_| CompanionError::Operation("Apple device service timed out".into()))?
            .map_err(|error| CompanionError::DeviceServiceUnavailable(error.to_string()))?;
        if output.stdout.len() > MAX_STDOUT_BYTES || output.stderr.len() > 1024 * 1024 {
            return Err(CompanionError::Operation(
                "device service returned oversized output".into(),
            ));
        }
        if !output.status.success() {
            let detail = String::from_utf8_lossy(&output.stderr);
            let detail = detail.lines().take(8).collect::<Vec<_>>().join(" ");
            return Err(CompanionError::Operation(if detail.is_empty() {
                "device operation failed".into()
            } else {
                detail
            }));
        }
        Ok(output.stdout)
    }
}

#[async_trait]
impl DeviceProvider for Pymobiledevice3Provider {
    async fn discover(&self) -> Result<Vec<DeviceInfo>> {
        let args = vec!["usbmux".into(), "list".into(), "--usb".into()];
        let output = match self.run(&args).await {
            Ok(output) => output,
            Err(error) => {
                self.available.store(false, Ordering::Relaxed);
                return Err(error);
            }
        };
        self.available.store(true, Ordering::Relaxed);
        let values: Vec<Value> = serde_json::from_slice(&output).map_err(|_| {
            CompanionError::Operation("device service returned unexpected discovery data".into())
        })?;
        Ok(values.into_iter().filter_map(parse_device_info).collect())
    }

    async fn installed_apps(&self, udid: &str) -> Result<Vec<InstalledApp>> {
        validate_udid(udid)?;
        let args = vec![
            "--udid".into(),
            udid.into(),
            "apps".into(),
            "list".into(),
            "--type".into(),
            "User".into(),
        ];
        let output = self.run(&args).await?;
        let values: Value = serde_json::from_slice(&output).map_err(|_| {
            CompanionError::Operation("device service returned unexpected app inventory".into())
        })?;
        Ok(parse_installed_apps(values))
    }

    async fn install(&self, udid: &str, package: &std::path::Path) -> Result<()> {
        validate_udid(udid)?;
        if !package.is_file() || package.extension().and_then(|ext| ext.to_str()) != Some("ipa") {
            return Err(CompanionError::InvalidPackage(
                "install input must be a managed IPA file".into(),
            ));
        }
        let args = vec![
            "--udid".into(),
            udid.into(),
            "apps".into(),
            "install".into(),
            package.to_string_lossy().into_owned(),
            "--developer".into(),
        ];
        self.run(&args).await.map(|_| ())
    }

    async fn uninstall(&self, udid: &str, bundle_identifier: &str) -> Result<()> {
        validate_udid(udid)?;
        if !valid_bundle_identifier(bundle_identifier) {
            return Err(CompanionError::InvalidRequest(
                "invalid bundle identifier".into(),
            ));
        }
        let args = vec![
            "--udid".into(),
            udid.into(),
            "apps".into(),
            "uninstall".into(),
            bundle_identifier.into(),
        ];
        self.run(&args).await.map(|_| ())
    }
}

fn find_on_path(names: &[&str]) -> Option<PathBuf> {
    let directories: Vec<PathBuf> = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .collect();
    directories
        .into_iter()
        .flat_map(|directory| {
            names
                .iter()
                .map(move |name| directory.join(name).to_owned())
        })
        .find(|path| path.is_file())
}

fn validate_udid(udid: &str) -> Result<()> {
    if udid.len() < 24
        || udid.len() > 64
        || !udid
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err(CompanionError::InvalidRequest(
            "invalid device identifier".into(),
        ));
    }
    Ok(())
}

fn valid_bundle_identifier(value: &str) -> bool {
    let components: Vec<_> = value.split('.').collect();
    components.len() >= 2
        && components.iter().all(|part| {
            !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

fn find_string(value: &Value, keys: &[&str]) -> Option<String> {
    match value {
        Value::Object(object) => {
            for key in keys {
                if let Some(text) = object.get(*key).and_then(Value::as_str) {
                    return Some(text.to_owned());
                }
            }
            object.values().find_map(|item| find_string(item, keys))
        }
        Value::Array(values) => values.iter().find_map(|item| find_string(item, keys)),
        _ => None,
    }
}

fn parse_device_info(value: Value) -> Option<DeviceInfo> {
    // `usbmux list` performs a lockdown handshake with autopair disabled and
    // returns only devices this host has already trusted. Never infer trust
    // from a missing JSON field.
    let udid = find_string(&value, &["udid", "UDID", "UniqueDeviceID", "serial"])?;
    if !validate_udid(&udid).is_ok() {
        return None;
    }
    Some(DeviceInfo {
        trusted: true,
        udid,
        name: find_string(&value, &["device_name", "DeviceName", "name", "Name"])
            .unwrap_or_else(|| "iPhone".into()),
        product_type: find_string(&value, &["product_type", "ProductType"]),
        product_version: find_string(&value, &["product_version", "ProductVersion"]),
        build_version: find_string(&value, &["build_version", "BuildVersion"]),
        // This is not exposed by the current usbmux short-info response.
        // Unknown must stay unknown so the UI never asserts it is enabled.
        developer_mode: value
            .get("developer_mode")
            .and_then(Value::as_bool)
            .or_else(|| value.get("DeveloperMode").and_then(Value::as_bool)),
    })
}

fn parse_installed_apps(value: Value) -> Vec<InstalledApp> {
    match value {
        Value::Array(values) => values
            .into_iter()
            .filter_map(|value| parse_installed_app(None, value))
            .collect(),
        Value::Object(values) => values
            .into_iter()
            .filter_map(|(bundle, value)| parse_installed_app(Some(&bundle), value))
            .collect(),
        _ => Vec::new(),
    }
}

fn parse_installed_app(bundle_key: Option<&str>, value: Value) -> Option<InstalledApp> {
    let bundle_identifier = find_string(
        &value,
        &["CFBundleIdentifier", "BundleIdentifier", "bundleIdentifier"],
    )
    .or_else(|| bundle_key.map(ToOwned::to_owned))
    .filter(|value| valid_bundle_identifier(value))?;
    Some(InstalledApp {
        bundle_identifier,
        version: find_string(
            &value,
            &["CFBundleShortVersionString", "Version", "version"],
        ),
        build: find_string(&value, &["CFBundleVersion", "Build", "build"]),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_realistic_upstream_inventory_shape() {
        let app = parse_installed_apps(serde_json::json!({"org.example.reader": {
            "CFBundleIdentifier": "org.example.reader",
            "CFBundleShortVersionString": "2.3.1",
            "CFBundleVersion": "91"
        }}))
        .remove(0);
        assert_eq!(app.bundle_identifier, "org.example.reader");
        assert_eq!(app.version.as_deref(), Some("2.3.1"));
        assert_eq!(app.build.as_deref(), Some("91"));
    }

    #[test]
    fn discovers_short_info_and_does_not_infer_unknown_developer_mode() {
        let device = parse_device_info(serde_json::json!({
            "udid": "0123456789abcdef0123456789abcdef01234567",
            "device_name": "Test iPhone",
            "product_version": "26.0"
        }))
        .unwrap();
        assert!(device.trusted);
        assert_eq!(device.name, "Test iPhone");
        assert_eq!(device.developer_mode, None);
    }

    #[test]
    fn rejects_shell_injection_values_before_spawn() {
        assert!(validate_udid("$(calc.exe)").is_err());
        assert!(!valid_bundle_identifier("com.example;whoami"));
        assert!(valid_bundle_identifier("com.example.reader"));
    }
}
