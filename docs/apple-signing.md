# Apple Signing on Windows

## What this client supports

Companion can use a locally imported Apple Development `.p12`/`.pfx` and a `.mobileprovision`/`.provisionprofile` file for a specific device and matching app identifier. It does not authenticate to Apple services, create signing certificates, register devices, create provisioning profiles, or collect Apple Account credentials. No password or 2FA code is sent to DreyzeStore servers.

The Windows flow is: receive `VerifiedPackage` → revalidate → require a profile that authorizes the package's bundle ID and contains the connected UDID → sign locally → check the resulting executable and signing certificate → install over the trusted Apple device service → query device inventory and confirm exact bundle ID/version/build.

The signing provider keeps the P12 and profile DPAPI-protected and the P12 password in Windows Credential Manager. zsign needs a short-lived P12 file while it signs; Companion places it only in its app-data signing workspace, deletes that workspace after use, and cleans interrupted UUID workspaces at startup. This is local at-rest protection, not secure disk erasure.

## Personal Team and paid membership

Apple's current account documentation says Personal Team provisioning is managed in Xcode and documents up to 10 App IDs, 3 devices, and 3 installed apps per device; those registrations and provisioning profiles expire after 7 days. This Windows-only Companion does not automate the Xcode Personal Team provisioning flow. An operator must supply a profile and certificate created through an Apple-supported workflow on a system that can create them.

An Apple Developer Program membership is optional for the project; DreyzeStore does not purchase it or require it. A paid team can provide Apple Development certificates and device-matched development profiles through Apple's developer portal. Device registration and profile eligibility remain subject to Apple's current account rules.

Apple describes Developer Mode as a user-confirmed safeguard for development-signed installs, including local IPA installation via Apple Configurator. The device owner must enable it manually in Settings and confirm the restart prompt. Companion does not silently change the setting. Current `pymobiledevice3 usbmux list` metadata does not expose a Developer Mode field, so the dashboard may show “unknown”; the installation service/device remains the final authority.

## Compatibility and expiry

- The imported profile must authorize the package bundle identifier and include the target iPhone UDID.
- Companion rejects an expired profile and displays its expiry when it can parse the profile.
- The P12 certificate expiry is not currently exposed in dashboard status. Signing checks are performed by zsign when an install is attempted.
- The same Apple team/application identity must continue to authorize the app. Changing bundle ID, team, entitlements, or profile may prevent an update or preserve app data as expected.
- A free Personal Team profile must be reprovisioned and the app reinstalled when Apple expires it. DreyzeStore does not promise permanent signing.
- The current refresh endpoint re-signs/reinstalls the stored original of the same release. New-version selection is deferred to PHASE 7.

## References

- [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/)
- [Apple device registration overview](https://developer.apple.com/help/account/devices/devices-overview/)
- [Apple provisioning profiles technical note](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple registered-device app distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
