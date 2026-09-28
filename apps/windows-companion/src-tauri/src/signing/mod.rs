pub mod apple_account;
pub mod zsign;

use crate::{
    error::Result,
    models::{SignedPackage, SigningStatus, ValidatedPackage},
};
use async_trait::async_trait;
use std::sync::Arc;

/// Chooses local Apple Account provisioning only after the user has signed in,
/// selected a team, and explicitly registered the connected iPhone. Existing
/// imported signing files remain the fallback.
pub struct CompositeSigningProvider {
    pub imported: Arc<zsign::AppleDevelopmentSigningProvider>,
    pub apple_account: Arc<apple_account::IsideloadAppleAccountProvider>,
}

impl CompositeSigningProvider {
    pub fn new(
        imported: Arc<zsign::AppleDevelopmentSigningProvider>,
        apple_account: Arc<apple_account::IsideloadAppleAccountProvider>,
    ) -> Self {
        Self {
            imported,
            apple_account,
        }
    }

    fn automatic_ready(&self, udid: &str) -> bool {
        self.apple_account.can_sign_for_device(udid)
    }
}

#[async_trait]
impl zsign::SigningProvider for CompositeSigningProvider {
    fn validate_provisioning(&self, package: &ValidatedPackage, target_udid: &str) -> Result<()> {
        if self.automatic_ready(target_udid) {
            self.apple_account
                .validate_provisioning(package, target_udid)
        } else {
            self.imported.validate_provisioning(package, target_udid)
        }
    }

    fn validate_device(&self, target_udid: &str) -> Result<()> {
        if self.automatic_ready(target_udid) {
            self.apple_account.validate_device(target_udid)
        } else {
            self.imported.validate_device(target_udid)
        }
    }

    async fn sign(&self, package: &ValidatedPackage, target_udid: &str) -> Result<SignedPackage> {
        if self.automatic_ready(target_udid) {
            self.apple_account.sign(package, target_udid).await
        } else {
            self.imported.sign(package, target_udid).await
        }
    }

    fn status(&self) -> SigningStatus {
        let apple_status = self.apple_account.status();
        if apple_status.account_kind.as_deref() == Some("Apple Account local provisioning")
            && apple_status.identity_label.is_some()
        {
            apple_status
        } else {
            self.imported.status()
        }
    }
}
