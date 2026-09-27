use crate::error::{CompanionError, Result};
use chrono::{DateTime, Duration, Utc};
use rand::{Rng, distr::Alphanumeric};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, sync::Mutex};
use subtle::ConstantTimeEq;

const PAIRING_CODE_TTL_SECONDS: i64 = 120;
const MAX_CLOCK_SKEW_SECONDS: i64 = 60;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingOffer {
    pub code: String,
    pub expires_at: DateTime<Utc>,
}

pub trait PairingSecretStore: Send + Sync {
    fn load_token_hash(&self) -> Result<Option<String>>;
    fn save_token_hash(&self, value: &str) -> Result<()>;
    fn clear_token_hash(&self) -> Result<()>;
}

struct PendingCode {
    hash: [u8; 32],
    expires_at: DateTime<Utc>,
}

pub struct PairingManager {
    pending: Mutex<Option<PendingCode>>,
    token_hash: Mutex<Option<[u8; 32]>>,
    client_id: Mutex<Option<String>>,
    client_last_seen_at: Mutex<Option<DateTime<Utc>>>,
    seen_nonces: Mutex<HashMap<String, DateTime<Utc>>>,
    secrets: Box<dyn PairingSecretStore>,
}

impl PairingManager {
    pub fn new(secrets: Box<dyn PairingSecretStore>) -> Result<Self> {
        let stored = secrets.load_token_hash()?;
        let binding = stored.and_then(|value| {
            let mut parts = value.splitn(3, '|');
            if parts.next()? != "v1" {
                return None;
            }
            let client_id = parts.next()?;
            if !valid_client_id(client_id) {
                return None;
            }
            let token_hash = hex::decode(parts.next()?)
                .ok()
                .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())?;
            Some((token_hash, client_id.to_owned()))
        });
        Ok(Self {
            pending: Mutex::new(None),
            token_hash: Mutex::new(binding.as_ref().map(|(hash, _)| *hash)),
            client_id: Mutex::new(binding.map(|(_, client_id)| client_id)),
            client_last_seen_at: Mutex::new(None),
            seen_nonces: Mutex::new(HashMap::new()),
            secrets,
        })
    }

    pub fn begin(&self) -> PairingOffer {
        let code = rand::rng()
            .sample_iter(&Alphanumeric)
            .take(12)
            .map(char::from)
            .collect::<String>()
            .to_uppercase();
        let expires_at = Utc::now() + Duration::seconds(PAIRING_CODE_TTL_SECONDS);
        let hash: [u8; 32] = Sha256::digest(code.as_bytes()).into();
        *self.pending.lock().expect("pairing mutex poisoned") =
            Some(PendingCode { hash, expires_at });
        PairingOffer { code, expires_at }
    }

    pub fn complete(&self, supplied_code: &str, client_id: &str) -> Result<String> {
        if supplied_code.len() != 12 || !supplied_code.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return Err(CompanionError::InvalidPairingCode);
        }
        if !valid_client_id(client_id) {
            return Err(CompanionError::InvalidRequest(
                "invalid paired client identifier".into(),
            ));
        }
        let mut pending = self.pending.lock().expect("pairing mutex poisoned");
        let current = pending.take().ok_or(CompanionError::InvalidPairingCode)?;
        if current.expires_at < Utc::now() {
            return Err(CompanionError::InvalidPairingCode);
        }
        let candidate: [u8; 32] =
            Sha256::digest(supplied_code.to_ascii_uppercase().as_bytes()).into();
        if !bool::from(current.hash.ct_eq(&candidate)) {
            return Err(CompanionError::InvalidPairingCode);
        }
        let token = rand::rng()
            .sample_iter(&Alphanumeric)
            .take(64)
            .map(char::from)
            .collect::<String>();
        let token_hash: [u8; 32] = Sha256::digest(token.as_bytes()).into();
        self.secrets
            .save_token_hash(&format!("v1|{client_id}|{}", hex::encode(token_hash)))?;
        *self.token_hash.lock().expect("pairing mutex poisoned") = Some(token_hash);
        *self.client_id.lock().expect("pairing mutex poisoned") = Some(client_id.to_owned());
        self.seen_nonces
            .lock()
            .expect("nonce mutex poisoned")
            .clear();
        Ok(token)
    }

    pub fn authenticate(
        &self,
        token: &str,
        client_id: &str,
        nonce: &str,
        timestamp: i64,
    ) -> Result<()> {
        if nonce.len() < 16
            || nonce.len() > 128
            || !nonce
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return Err(CompanionError::ReplayRejected);
        }
        let now = Utc::now().timestamp();
        if (now - timestamp).abs() > MAX_CLOCK_SKEW_SECONDS {
            return Err(CompanionError::ReplayRejected);
        }
        let candidate: [u8; 32] = Sha256::digest(token.as_bytes()).into();
        let expected = self
            .token_hash
            .lock()
            .expect("token mutex poisoned")
            .ok_or(CompanionError::PairingRequired)?;
        let expected_client_id = self.client_id.lock().expect("pairing mutex poisoned");
        let expected_client_id = expected_client_id
            .as_deref()
            .ok_or(CompanionError::PairingRequired)?;
        if !bool::from(expected_client_id.as_bytes().ct_eq(client_id.as_bytes())) {
            return Err(CompanionError::AuthenticationFailed);
        }
        if !bool::from(expected.ct_eq(&candidate)) {
            return Err(CompanionError::AuthenticationFailed);
        }
        let mut seen = self.seen_nonces.lock().expect("nonce mutex poisoned");
        seen.retain(|_, seen_at| *seen_at + Duration::minutes(5) > Utc::now());
        if seen.contains_key(nonce) {
            return Err(CompanionError::ReplayRejected);
        }
        seen.insert(nonce.to_owned(), Utc::now());
        *self
            .client_last_seen_at
            .lock()
            .expect("last-seen mutex poisoned") = Some(Utc::now());
        Ok(())
    }

    pub fn is_paired(&self) -> bool {
        self.token_hash
            .lock()
            .expect("token mutex poisoned")
            .is_some()
    }

    pub fn client_last_seen_at(&self) -> Option<DateTime<Utc>> {
        *self
            .client_last_seen_at
            .lock()
            .expect("last-seen mutex poisoned")
    }

    pub fn forget(&self) -> Result<()> {
        self.secrets.clear_token_hash()?;
        *self.token_hash.lock().expect("token mutex poisoned") = None;
        *self.client_id.lock().expect("pairing mutex poisoned") = None;
        *self
            .client_last_seen_at
            .lock()
            .expect("last-seen mutex poisoned") = None;
        self.seen_nonces
            .lock()
            .expect("nonce mutex poisoned")
            .clear();
        Ok(())
    }
}

fn valid_client_id(client_id: &str) -> bool {
    uuid::Uuid::parse_str(client_id).is_ok_and(|value| value.to_string() == client_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct MemorySecrets(Arc<Mutex<Option<String>>>);
    impl PairingSecretStore for MemorySecrets {
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

    fn manager() -> PairingManager {
        PairingManager::new(Box::new(MemorySecrets::default())).unwrap()
    }

    #[test]
    fn pairing_code_is_one_time_and_token_is_device_secret() {
        let manager = manager();
        let offer = manager.begin();
        let client_id = "01234567-89ab-cdef-0123-456789abcdef";
        let token = manager
            .complete(&offer.code.to_lowercase(), client_id)
            .unwrap();
        assert_eq!(token.len(), 64);
        assert!(manager.is_paired());
        assert!(matches!(
            manager.complete(&offer.code, client_id),
            Err(CompanionError::InvalidPairingCode)
        ));
    }

    #[test]
    fn invalid_pairing_code_does_not_pair() {
        let manager = manager();
        manager.begin();
        assert!(matches!(
            manager.complete("wrong-code", "01234567-89ab-cdef-0123-456789abcdef"),
            Err(CompanionError::InvalidPairingCode)
        ));
        assert!(!manager.is_paired());
    }

    #[test]
    fn requests_require_token_fresh_timestamp_and_unique_nonce() {
        let manager = manager();
        let offer = manager.begin();
        let client_id = "01234567-89ab-cdef-0123-456789abcdef";
        let token = manager.complete(&offer.code, client_id).unwrap();
        manager
            .authenticate(
                &token,
                client_id,
                "0123456789abcdef",
                Utc::now().timestamp(),
            )
            .unwrap();
        assert!(matches!(
            manager.authenticate(
                &token,
                client_id,
                "0123456789abcdef",
                Utc::now().timestamp()
            ),
            Err(CompanionError::ReplayRejected)
        ));
        assert!(matches!(
            manager.authenticate(
                &token,
                "ffffffff-ffff-ffff-ffff-ffffffffffff",
                "abcdef0123456789",
                Utc::now().timestamp()
            ),
            Err(CompanionError::AuthenticationFailed)
        ));
        assert!(matches!(
            manager.authenticate("bad", client_id, "fedcba9876543210", Utc::now().timestamp()),
            Err(CompanionError::AuthenticationFailed)
        ));
        assert!(matches!(
            manager.authenticate(&token, client_id, "freshnonce000000", 1),
            Err(CompanionError::ReplayRejected)
        ));
    }

    #[test]
    fn pairing_token_hash_survives_manager_restart() {
        let store = MemorySecrets::default();
        let manager = PairingManager::new(Box::new(store.clone())).unwrap();
        let offer = manager.begin();
        let client_id = "01234567-89ab-cdef-0123-456789abcdef";
        let token = manager.complete(&offer.code, client_id).unwrap();
        let restarted = PairingManager::new(Box::new(store)).unwrap();
        restarted
            .authenticate(
                &token,
                client_id,
                "fedcba9876543210",
                Utc::now().timestamp(),
            )
            .unwrap();
    }
}
