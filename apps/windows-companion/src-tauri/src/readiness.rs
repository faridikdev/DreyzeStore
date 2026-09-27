use crate::models::{DeviceInfo, DeviceReadiness, ReadinessCheck, ReadinessStatus, SigningStatus};
use chrono::{DateTime, Utc};

pub fn build_device_readiness(
    run_at: DateTime<Utc>,
    apple_mobile_device_service: ReadinessCheck,
    pymobiledevice3: ReadinessCheck,
    devices: &[DeviceInfo],
    signing: &SigningStatus,
    provisioning_for_device: Option<std::result::Result<(), String>>,
    paired: bool,
) -> DeviceReadiness {
    let device = devices.iter().find(|device| device.trusted);
    let usb_connection = if device.is_some() {
        check(
            ReadinessStatus::Pass,
            "A trusted iPhone is visible over USB.",
        )
    } else if pymobiledevice3.status == ReadinessStatus::Pass {
        check(
            ReadinessStatus::Unknown,
            "No trusted iPhone was returned. This service cannot distinguish an unplugged phone from one waiting for Trust confirmation.",
        )
    } else {
        check(
            ReadinessStatus::Unknown,
            "USB presence could not be checked because the device service is unavailable.",
        )
    };
    let trust = match device {
        Some(_) => check(
            ReadinessStatus::Pass,
            "The iPhone has a usable host pairing record.",
        ),
        None => check(
            ReadinessStatus::Unknown,
            "Connect and unlock the iPhone. If prompted, tap Trust and enter its passcode.",
        ),
    };
    let developer_mode = match device.and_then(|device| device.developer_mode) {
        Some(true) => check(
            ReadinessStatus::Pass,
            "Developer Mode is reported as enabled.",
        ),
        Some(false) => check(
            ReadinessStatus::Fail,
            "Enable Developer Mode on the iPhone in Settings → Privacy & Security, then restart it.",
        ),
        None => check(
            ReadinessStatus::Unknown,
            "The current Apple device service does not report Developer Mode. Check Settings → Privacy & Security on the iPhone.",
        ),
    };
    let now = run_at;
    let signing_identity = match signing.certificate_expires_at {
        Some(expiry) if expiry > now && signing.identity_label.is_some() => check(
            ReadinessStatus::Pass,
            "The imported P12 opens and its certificate is present in the provisioning profile.",
        ),
        Some(_) => check(
            ReadinessStatus::Fail,
            "The imported Apple Development certificate has expired.",
        ),
        None => check(
            ReadinessStatus::Fail,
            signing.limitation.as_deref().unwrap_or(
                "Import a valid Apple Development P12 and matching provisioning profile.",
            ),
        ),
    };
    let provisioning = match provisioning_for_device {
        Some(Ok(())) => check(
            ReadinessStatus::Pass,
            "The profile data is current and lists the connected iPhone and matching signing certificate. iOS performs the final profile-signature and capability checks during install.",
        ),
        Some(Err(details)) => check(ReadinessStatus::Fail, &details),
        None => check(
            ReadinessStatus::Unknown,
            "Connect a trusted iPhone to check its UDID against the provisioning profile.",
        ),
    };

    DeviceReadiness {
        run_at,
        apple_mobile_device_service,
        usb_connection,
        trust,
        developer_mode,
        pymobiledevice3,
        signing_identity,
        provisioning,
        dreyze_pairing: if paired {
            check(
                ReadinessStatus::Pass,
                "DreyzeStore is paired with this Companion.",
            )
        } else {
            check(
                ReadinessStatus::Fail,
                "Pair this Companion from DreyzeStore → Settings → Companion on the iPhone.",
            )
        },
    }
}

fn check(status: ReadinessStatus, details: &str) -> ReadinessCheck {
    ReadinessCheck {
        status,
        details: details.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn signing(now: DateTime<Utc>) -> SigningStatus {
        SigningStatus {
            configured: true,
            identity_label: Some("Development profile".into()),
            certificate_expires_at: Some(now + Duration::days(30)),
            provisioning_expires_at: Some(now + Duration::days(30)),
            team_id: Some("TEAM123".into()),
            account_kind: Some("Imported Apple Development identity".into()),
            limitation: None,
        }
    }

    fn pass(details: &str) -> ReadinessCheck {
        ReadinessCheck {
            status: ReadinessStatus::Pass,
            details: details.into(),
        }
    }

    #[test]
    fn no_device_is_reported_unknown_instead_of_fabricating_usb_or_trust_failure() {
        let now = Utc::now();
        let readiness = build_device_readiness(
            now,
            pass("Service running."),
            pass("usbmux list returned successfully."),
            &[],
            &signing(now),
            None,
            false,
        );
        assert_eq!(readiness.usb_connection.status, ReadinessStatus::Unknown);
        assert_eq!(readiness.trust.status, ReadinessStatus::Unknown);
        assert_eq!(readiness.developer_mode.status, ReadinessStatus::Unknown);
        assert_eq!(readiness.provisioning.status, ReadinessStatus::Unknown);
    }

    #[test]
    fn trusted_device_readiness_uses_reported_developer_mode_and_profile_validation() {
        let now = Utc::now();
        let device = DeviceInfo {
            udid: "0123456789abcdef0123456789abcdef".into(),
            name: "iPhone".into(),
            product_type: Some("iPhone18,1".into()),
            product_version: Some("26.0".into()),
            build_version: None,
            developer_mode: Some(true),
            trusted: true,
        };
        let readiness = build_device_readiness(
            now,
            pass("Service running."),
            pass("usbmux list returned the connected phone."),
            &[device],
            &signing(now),
            Some(Ok(())),
            true,
        );
        assert_eq!(readiness.usb_connection.status, ReadinessStatus::Pass);
        assert_eq!(readiness.trust.status, ReadinessStatus::Pass);
        assert_eq!(readiness.developer_mode.status, ReadinessStatus::Pass);
        assert_eq!(readiness.provisioning.status, ReadinessStatus::Pass);
        assert_eq!(readiness.dreyze_pairing.status, ReadinessStatus::Pass);
    }

    #[test]
    fn expired_certificate_fails_readiness_without_emitting_secret_material() {
        let now = Utc::now();
        let mut identity = signing(now);
        identity.certificate_expires_at = Some(now - Duration::seconds(1));
        let readiness = build_device_readiness(
            now,
            pass("Service running."),
            pass("usbmux list returned successfully."),
            &[],
            &identity,
            None,
            false,
        );
        assert_eq!(readiness.signing_identity.status, ReadinessStatus::Fail);
        let serialized = serde_json::to_string(&readiness).unwrap();
        assert!(!serialized.contains("password"));
        assert!(!serialized.contains("token"));
        assert!(!serialized.contains("TEAM123"));
    }
}
