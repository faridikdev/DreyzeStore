# Apple signing on Windows

## Decision

Windows Companion supports user-imported Apple Development signing files. It does **not** sign into Apple Account, collect Apple ID/password or 2FA codes, reuse an Apple web session, register devices with Apple, create App IDs/profiles, or make signing materials in the cloud.

This is a deliberate product boundary. Apple documents Personal Team provisioning as Xcode-managed; the documented physical-device workflow signs in to Xcode with a Personal Apple Account or Developer Program account, registers the device, and creates a development profile there. Apple does not document a Windows API for Personal Team login/provisioning. Integrating reverse-engineered Apple authentication or an Anisette service would not satisfy the project's requirement to use supported flows.

## What works

| Setup | Windows Companion support | Required material / limit |
|---|---|---|
| Free Apple Personal Team | Import only | Create the Apple Development certificate/profile in Xcode on a Mac, then import the user's matching `.p12` and device-specific `.mobileprovision`. Apple's current documentation says Personal Team profiles expire after 7 days, with app/device limits; reinstall/reprovision when they expire. |
| Paid Apple Developer Program team | Import only | Import a team-owned Apple Development `.p12` and a current development profile for the app and device. The Companion does not require paid membership. |
| Paid team through App Store Connect API | Not implemented | Apple documents APIs for bundle IDs, certificates, devices, and profiles. Team API key requires an Admin role and is broad team access; Individual API keys cannot call provisioning endpoints. A future flow would need local CSR/key generation and secure, user-controlled API-key storage. |
| Apple Account login or 2FA in Companion | Not implemented | No credentials/session form exists. Complete authentication in Xcode or Apple's supported tools on a Mac. |
| Anisette / reverse-engineered Apple authentication | Not used | AltStore and other sideloaders document their own Apple sign-in flow; SideStore documents community-hosted Anisette V3 endpoints. These are implementation-specific and not an Apple provisioning API. DreyzeStore does not operate or depend on an Anisette host. |

## Current local flow

`VerifiedPackage` transfer → Windows independently inspects the IPA and digest → imports a user-provided `.p12` and `.mobileprovision` → Windows CryptoAPI opens the P12 without persisting its private key → the P12 certificate must match a certificate embedded in the profile → the profile must authorize the app bundle ID and target UDID and remain current → local `zsign` operation → device install over the trusted Apple device service → inventory confirms exact bundle ID/version/build.

P12/profile bytes are DPAPI-protected; the P12 password is in Windows Credential Manager. A short-lived P12 file is used for the signer and removed with its temporary signing workspace. File deletion is not secure erasure. Apple credentials and signing materials are never sent to the DreyzeStore backend.

The `Signing` screen shows the imported profile label, team identifier, certificate expiry, and profile expiry. **Run Diagnostics** tests the local service, device bridge, trust state, Developer Mode reportability, signing files, profile/device match, and Companion pairing. Its profile check reads the profile's claims; iOS still verifies Apple's profile signature and capabilities when installing. The DreyzeStore iOS settings view gets the actual certificate/profile dates from its pinned local Companion connection.

The **Test Installation** action only accepts an IPA whose bundle ID begins `org.dreyzestore.test.`. It recomputes the digest and invokes the same package validator, signing provider, install coordinator, and exact inventory confirmation used by the normal Companion pipeline. The test app can be removed only through its dedicated cleanup button, which confirms it is absent from device inventory. This test action is a local user-selected package path; it does not turn arbitrary server metadata into a `VerifiedPackage` or weaken normal iOS download verification.

See [the physical iPhone test plan](physical-device-install-test.md) for the GUI procedure. No physical iPhone was available for the Phase 6.6 work, so real device installation is **NOT VERIFIED**.

## Capability and compatibility limits

- Apple says a free Personal Team is managed directly in Xcode. Its App IDs and registered devices expire after 7 days, and development provisioning profiles expire 7 days after issuance; its app/device slots are limited. DreyzeStore does not promise permanent signing.
- Developer Mode is an owner-controlled setting. Apple requires the on-device restart and confirmation flow. Current `pymobiledevice3 usbmux list --usb` short-info does not report it, so Windows diagnostics use `Unknown`; the tester must check Settings manually.
- A provisioning profile must match the requested bundle ID, include the connected UDID, and authorize the imported certificate. The Companion does not rewrite bundle IDs or provision capabilities.
- The profile's authorized device/app IDs/certificates are checked, but Windows Companion does not independently decode and rewrite every app-signature entitlement. Unsupported capabilities, extensions, App Groups, iCloud, push, or other restricted entitlements may still be rejected by the signer or iOS. Apple says app entitlements must be authorized by the profile and advises using Xcode/Apple Code Signing Services rather than depending on undocumented signature structure.
- Refresh can re-sign and reinstall the same locally retained release if a current matching profile is imported. No stored Apple login, unattended Apple refresh session, or background personal-team refresh exists. New catalog version selection remains PHASE 7.
- `Installed` is returned only after a successful install command and device inventory containing the expected app version/build. A test run or simulator test is not a physical-device verification.

## Research notes

- **Apple Personal Team:** Apple's account help says Personal Team provisioning is managed by Xcode, documents its limits and 7-day profile duration, and distinguishes a free Personal Team from Developer Program membership.
- **Paid teams:** Apple documents App Store Connect API provisioning resources. API keys are for App Store Connect API JWTs, not general Apple Account authentication; Individual keys cannot use provisioning endpoints, while Team keys require an Admin and have team-wide app access.
- **Windows device channel:** Current upstream `pymobiledevice3` installation notes require Apple's classic iTunes package for Apple Mobile Device Service on Windows; its documented `apps install` commands form the local device-install bridge used by Companion.
- **Other sideloaders:** AltStore's Windows FAQ asks the user to enter Apple credentials into AltServer and says they are sent to Apple. Sideloadly describes free-account support and remote Anisette metadata; SideStore's upstream repository lists community Anisette services. These product claims do not create an Apple-documented Windows Personal Team provisioning API.
- **iOS Developer Mode and entitlements:** Apple documents Developer Mode as an explicit device-owner confirmation for local development installs and describes provisioning profiles as the allowlist for app-signature entitlements.

## Sources

- [Apple developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple: run apps on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-a-simulated-or-physical-devices)
- [Apple: enable Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple: provisioning profile entitlements, TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple App Store Connect API provisioning overview](https://developer.apple.com/app-store-connect/api/)
- [Apple API key access and permissions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Apple Profiles API](https://developer.apple.com/documentation/appstoreconnectapi/profiles)
- [pymobiledevice3 Windows installation guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/installation.md)
- [pymobiledevice3 app CLI source](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/apps.py)
- [AltStore Windows setup FAQ](https://github.com/altstoreio/FAQ/blob/main/altstore-world/how-to-install-altstore-windows.md)
- [AltStore Anisette implementation source](https://github.com/altstoreio/AltStore/blob/marketplace/AltServer/Anisette%20Data/AnisetteDataManager.swift)
- [Sideloadly FAQ](https://sideloadly.io/faq)
- [SideStore Anisette server project](https://github.com/SideStore/anisette-servers)

The App Store Connect API can enable a later **local** paid-team provisioning workflow, but it cannot make the free Personal Team flow documented or remove Apple's account/device/profile constraints. No third-party source code or credentials from these projects were copied into DreyzeStore for this phase.
