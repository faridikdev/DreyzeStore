use crate::{
    error::{CompanionError, Result},
    security::pairing::PairingSecretStore,
};
use chrono::{DateTime, Utc};
use std::{
    fs,
    path::{Path, PathBuf},
};
use zeroize::{Zeroize, Zeroizing};

const KEYRING_SERVICE: &str = "com.dreyzestore.companion";
const PAIRING_ACCOUNT: &str = "paired-token-sha256";
const SIGNING_PASSWORD_ACCOUNT: &str = "apple-development-p12-password";
const LOCAL_TLS_KEY_ACCOUNT: &str = "local-api-tls-private-key-pem";
const LOCAL_TLS_IP_ACCOUNT: &str = "local-api-tls-interface";

#[derive(Default)]
pub struct WindowsCredentialStore;

impl WindowsCredentialStore {
    pub fn get(account: &str) -> Result<Option<String>> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, account)
            .map_err(|error| CompanionError::SecureStorage(error.to_string()))?;
        match entry.get_password() {
            Ok(secret) => Ok(Some(secret)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(CompanionError::SecureStorage(error.to_string())),
        }
    }

    pub fn set(account: &str, value: &str) -> Result<()> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, account)
            .map_err(|error| CompanionError::SecureStorage(error.to_string()))?;
        entry
            .set_password(value)
            .map_err(|error| CompanionError::SecureStorage(error.to_string()))
    }

    pub fn delete(account: &str) -> Result<()> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, account)
            .map_err(|error| CompanionError::SecureStorage(error.to_string()))?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(CompanionError::SecureStorage(error.to_string())),
        }
    }
}

pub fn tls_key_account() -> &'static str {
    LOCAL_TLS_KEY_ACCOUNT
}
pub fn tls_ip_account() -> &'static str {
    LOCAL_TLS_IP_ACCOUNT
}

impl PairingSecretStore for WindowsCredentialStore {
    fn load_token_hash(&self) -> Result<Option<String>> {
        Self::get(PAIRING_ACCOUNT)
    }
    fn save_token_hash(&self, value: &str) -> Result<()> {
        Self::set(PAIRING_ACCOUNT, value)
    }
    fn clear_token_hash(&self) -> Result<()> {
        Self::delete(PAIRING_ACCOUNT)
    }
}

#[derive(Clone, Debug)]
pub struct SigningIdentityVault {
    directory: PathBuf,
}

pub struct SigningMaterial {
    pub p12: Zeroizing<Vec<u8>>,
    pub mobileprovision: Zeroizing<Vec<u8>>,
    pub password: Zeroizing<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct P12Certificate {
    pub der: Vec<u8>,
    pub expires_at: DateTime<Utc>,
}

/// Reads certificate metadata from a P12 using the Windows certificate APIs.
/// The imported key material is marked non-persistent and the temporary store
/// is closed before this function returns. Private key bytes are never returned.
pub fn inspect_p12_certificates(p12: &[u8], password: &str) -> Result<Vec<P12Certificate>> {
    #[cfg(windows)]
    {
        windows_p12_certificates(p12, password)
    }
    #[cfg(not(windows))]
    {
        let _ = (p12, password);
        Err(CompanionError::SecureStorage(
            "P12 certificate inspection requires Windows certificate services".into(),
        ))
    }
}

#[cfg(windows)]
fn windows_p12_certificates(p12: &[u8], password: &str) -> Result<Vec<P12Certificate>> {
    use windows_sys::Win32::Security::Cryptography::{
        CERT_CONTEXT, CRYPT_INTEGER_BLOB, CertCloseStore, CertEnumCertificatesInStore,
        PFXImportCertStore, PKCS12_NO_PERSIST_KEY,
    };

    if p12.is_empty() || p12.len() > 4 * 1024 * 1024 || password.len() > 2048 {
        return Err(CompanionError::InvalidRequest(
            "signing identity exceeds supported limits".into(),
        ));
    }
    let password_wide = Zeroizing::new(
        password
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect::<Vec<u16>>(),
    );
    let mut blob = CRYPT_INTEGER_BLOB {
        cbData: p12.len() as u32,
        // CryptoAPI reads the buffer and does not mutate the caller's P12.
        pbData: p12.as_ptr().cast_mut(),
    };
    // SAFETY: `blob` points to a live, length-checked P12 buffer and the
    // password is NUL-terminated UTF-16 for the duration of the call. The
    // no-persist flag prevents certificate private keys being written to a
    // persistent Windows key store.
    let store =
        unsafe { PFXImportCertStore(&mut blob, password_wide.as_ptr(), PKCS12_NO_PERSIST_KEY) };
    if store.is_null() {
        return Err(CompanionError::SecureStorage(
            "P12 could not be opened with the supplied password or has no readable certificates"
                .into(),
        ));
    }

    let mut certificates = Vec::new();
    let mut previous: *const CERT_CONTEXT = std::ptr::null();
    loop {
        // SAFETY: `store` is a live certificate store. This API owns and frees
        // the prior context passed on the next iteration.
        let current = unsafe { CertEnumCertificatesInStore(store, previous) };
        if current.is_null() {
            break;
        }
        // SAFETY: CryptoAPI returned a valid context owned by `store`.
        let certificate = unsafe { &*current };
        if !certificate.pbCertEncoded.is_null()
            && certificate.cbCertEncoded > 0
            && certificate.cbCertEncoded <= 4 * 1024 * 1024
            && !certificate.pCertInfo.is_null()
        {
            // SAFETY: The DER pointer and length are supplied by a valid
            // CryptoAPI certificate context and copied before it is released.
            let der = unsafe {
                std::slice::from_raw_parts(
                    certificate.pbCertEncoded,
                    certificate.cbCertEncoded as usize,
                )
            }
            .to_vec();
            // SAFETY: `pCertInfo` is non-null and belongs to the context above.
            let expires_at = unsafe { filetime_to_datetime((*certificate.pCertInfo).NotAfter) };
            if let Some(expires_at) = expires_at {
                certificates.push(P12Certificate { der, expires_at });
            }
        }
        previous = current;
    }
    // SAFETY: This closes only the temporary in-memory certificate store.
    unsafe { CertCloseStore(store, 0) };

    if certificates.is_empty() {
        return Err(CompanionError::SecureStorage(
            "P12 contains no readable signing certificates".into(),
        ));
    }
    Ok(certificates)
}

#[cfg(windows)]
fn filetime_to_datetime(value: windows_sys::Win32::Foundation::FILETIME) -> Option<DateTime<Utc>> {
    let ticks = (u64::from(value.dwHighDateTime) << 32) | u64::from(value.dwLowDateTime);
    let seconds_since_windows_epoch = i128::from(ticks / 10_000_000);
    let unix_seconds = seconds_since_windows_epoch - 11_644_473_600i128;
    let unix_seconds = i64::try_from(unix_seconds).ok()?;
    let nanoseconds = ((ticks % 10_000_000) * 100) as u32;
    DateTime::<Utc>::from_timestamp(unix_seconds, nanoseconds)
}

impl SigningIdentityVault {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory }
    }

    pub fn import(&self, p12_path: &Path, provisioning_path: &Path, password: &str) -> Result<()> {
        if password.is_empty() || password.len() > 2048 {
            return Err(CompanionError::InvalidRequest(
                "use a non-empty P12 password (maximum 2048 bytes)".into(),
            ));
        }
        let p12 = Zeroizing::new(fs::read(p12_path)?);
        let profile = fs::read(provisioning_path)?;
        if p12.len() < 64
            || p12.len() > 4 * 1024 * 1024
            || profile.len() < 64
            || profile.len() > 4 * 1024 * 1024
        {
            return Err(CompanionError::InvalidRequest(
                "signing files exceed supported limits".into(),
            ));
        }
        fs::create_dir_all(&self.directory)?;
        let protected_p12 = dpapi_protect(&p12)?;
        let protected_profile = dpapi_protect(&profile)?;
        atomic_write(&self.directory.join("identity.p12.dpapi"), &protected_p12)?;
        atomic_write(
            &self.directory.join("profile.mobileprovision.dpapi"),
            &protected_profile,
        )?;
        WindowsCredentialStore::set(SIGNING_PASSWORD_ACCOUNT, password)?;
        Ok(())
    }

    pub fn load(&self) -> Result<SigningMaterial> {
        let p12_path = self.directory.join("identity.p12.dpapi");
        let profile_path = self.directory.join("profile.mobileprovision.dpapi");
        if !p12_path.is_file() || !profile_path.is_file() {
            return Err(CompanionError::SigningRequired);
        }
        let p12_cipher = fs::read(p12_path)?;
        let profile_cipher = fs::read(profile_path)?;
        let p12 = dpapi_unprotect(&p12_cipher)?;
        let mobileprovision = dpapi_unprotect(&profile_cipher)?;
        let password = WindowsCredentialStore::get(SIGNING_PASSWORD_ACCOUNT)?
            .ok_or(CompanionError::SigningRequired)?;
        Ok(SigningMaterial {
            p12,
            mobileprovision,
            password: Zeroizing::new(password),
        })
    }

    pub fn is_configured(&self) -> bool {
        self.directory.join("identity.p12.dpapi").is_file()
            && self
                .directory
                .join("profile.mobileprovision.dpapi")
                .is_file()
            && WindowsCredentialStore::get(SIGNING_PASSWORD_ACCOUNT)
                .ok()
                .flatten()
                .map(Zeroizing::new)
                .is_some()
    }

    pub fn remove(&self) -> Result<()> {
        if self.directory.exists() {
            fs::remove_dir_all(&self.directory)?;
        }
        WindowsCredentialStore::delete(SIGNING_PASSWORD_ACCOUNT)
    }
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let temporary = path.with_extension("new");
    fs::write(&temporary, bytes)?;
    if path.exists() {
        fs::remove_file(path)?;
    }
    fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(windows)]
fn dpapi_protect(input: &[u8]) -> Result<Vec<u8>> {
    windows_dpapi(input, true)
}

#[cfg(windows)]
fn dpapi_unprotect(input: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    windows_dpapi(input, false).map(Zeroizing::new)
}

#[cfg(not(windows))]
fn dpapi_protect(_input: &[u8]) -> Result<Vec<u8>> {
    Err(CompanionError::SecureStorage(
        "DPAPI identity storage requires Windows 11".into(),
    ))
}

#[cfg(not(windows))]
fn dpapi_unprotect(_input: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    Err(CompanionError::SecureStorage(
        "DPAPI identity storage requires Windows 11".into(),
    ))
}

#[cfg(windows)]
fn windows_dpapi(input: &[u8], protect: bool) -> Result<Vec<u8>> {
    use std::{ffi::c_void, ptr};
    const UI_FORBIDDEN: u32 = 0x00000001;
    #[repr(C)]
    struct DataBlob {
        cb_data: u32,
        pb_data: *mut u8,
    }
    #[link(name = "Crypt32")]
    unsafe extern "system" {
        fn CryptProtectData(
            data_in: *const DataBlob,
            description: *const u16,
            entropy: *const DataBlob,
            reserved: *mut c_void,
            prompt: *mut c_void,
            flags: u32,
            data_out: *mut DataBlob,
        ) -> i32;
        fn CryptUnprotectData(
            data_in: *const DataBlob,
            description: *mut *mut u16,
            entropy: *const DataBlob,
            reserved: *mut c_void,
            prompt: *mut c_void,
            flags: u32,
            data_out: *mut DataBlob,
        ) -> i32;
    }
    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }

    let entropy_bytes = b"DreyzeStore signing identity v1";
    let input = DataBlob {
        cb_data: input
            .len()
            .try_into()
            .map_err(|_| CompanionError::SecureStorage("secret is too large".into()))?,
        pb_data: input.as_ptr().cast_mut(),
    };
    let entropy = DataBlob {
        cb_data: entropy_bytes.len() as u32,
        pb_data: entropy_bytes.as_ptr().cast_mut(),
    };
    let mut output = DataBlob {
        cb_data: 0,
        pb_data: ptr::null_mut(),
    };
    let ok = unsafe {
        if protect {
            CryptProtectData(
                &input,
                ptr::null(),
                &entropy,
                ptr::null_mut(),
                ptr::null_mut(),
                UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                &entropy,
                ptr::null_mut(),
                ptr::null_mut(),
                UI_FORBIDDEN,
                &mut output,
            )
        }
    };
    if ok == 0 || output.pb_data.is_null() {
        return Err(CompanionError::SecureStorage(
            "Windows DPAPI operation failed".into(),
        ));
    }
    let result =
        unsafe { std::slice::from_raw_parts(output.pb_data, output.cb_data as usize).to_vec() };
    if !protect {
        unsafe {
            std::slice::from_raw_parts_mut(output.pb_data, output.cb_data as usize).zeroize();
        }
    }
    unsafe {
        LocalFree(output.pb_data.cast());
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn dpapi_round_trip_keeps_secret_encrypted_at_rest() {
        let value = b"test signing material";
        let protected = dpapi_protect(value).unwrap();
        assert_ne!(protected, value);
        assert_eq!(&*dpapi_unprotect(&protected).unwrap(), value);
    }

    #[cfg(windows)]
    #[test]
    fn parses_ephemeral_test_pfx_without_persisting_apple_credentials() {
        use std::process::Command;

        let id = uuid::Uuid::new_v4().to_string();
        let password = uuid::Uuid::new_v4().to_string();
        let pfx_path = std::env::temp_dir().join(format!("dreyzestore-{id}.pfx"));
        let script = r#"
            $ErrorActionPreference = 'Stop'
            try {
                $rsa = [System.Security.Cryptography.RSA]::Create(2048)
                $subject = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=DreyzeStore transient test only')
                $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($subject, $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $now = [System.DateTimeOffset]::UtcNow
                $certificate = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(1))
                $pfx = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $env:DREYZESTORE_TEST_PFX_PASSWORD)
                [System.IO.File]::WriteAllBytes($env:DREYZESTORE_TEST_PFX_PATH, $pfx)
            } catch {
                Write-Output 'DREYZE_TEST_PFX_GENERATION_FAILED'
                exit 21
            } finally {
                if ($certificate) { $certificate.Dispose() }
                if ($rsa) { $rsa.Dispose() }
            }
            Write-Output 'DREYZE_TEST_PFX_READY'
        "#;
        let setup = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .env("DREYZESTORE_TEST_PFX_PATH", &pfx_path)
            .env("DREYZESTORE_TEST_PFX_PASSWORD", &password)
            .output()
            .expect("Windows PowerShell is required for this Windows-only test");
        assert!(
            setup.status.success(),
            "transient test certificate setup failed: {}",
            String::from_utf8_lossy(&setup.stdout)
        );

        let pfx = fs::read(&pfx_path).expect("transient test PFX should exist");
        let certificates = inspect_p12_certificates(&pfx, &password).unwrap();
        assert!(!certificates.is_empty());
        assert!(
            certificates
                .iter()
                .all(|certificate| certificate.expires_at > Utc::now())
        );
        drop(certificates);
        drop(pfx);
        fs::remove_file(pfx_path).unwrap();
    }
}
