use crate::{
    error::{CompanionError, Result},
    security::pairing::PairingSecretStore,
};
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
        let p12 = fs::read(p12_path)?;
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
}
