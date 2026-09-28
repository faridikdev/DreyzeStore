# Windows Companion

DreyzeStore Windows Companion is a local Windows 11 desktop app for the stock-iOS installation path. It accepts only a `VerifiedPackage` transfer from a paired iPhone, validates the IPA again, signs with either the experimental local Apple Account provisioning provider or an imported Apple Development identity/profile, sends the signed package to the explicitly selected trusted iPhone, and reports `Installed` only after the iPhone's app inventory contains the exact bundle ID, version, and build. The Apple Account path is unofficial and has not been tested against live Apple services or a physical iPhone in this phase.

The public Cloudflare API is not involved in pairing, Apple authentication, signing, USB installation, uninstall, or refresh. The iPhone sends the verified package to the companion over the local LAN; it is not sent a second time to the store backend.

## Components

- `apps/windows-companion/src/` — React/Vite desktop UI and setup, signing, pairing, and install history views.
- `apps/windows-companion/src-tauri/src/` — Tauri shell, loopback-to-LAN pinned TLS API, DPAPI/Credential Manager storage, package validator, signer, and `pymobiledevice3` device provider.
- `ios/DreyzeStore/Installation/WindowsCompanionClient.swift` — iPhone pairing, TLS pinning, authenticated local requests, package upload, job polling, inventory, and uninstall.
- `scripts/build-zsign-windows.ps1` — reproducible Windows x64 build for upstream zsign revision `614caa8d1ca949e260e5746144aa52d27a4b08d6`.

## Build on Windows 11

Install Node.js 22.12+, Rust stable with the MSVC target, Visual Studio 2022 C++ build tools, and Python 3. The device service is not bundled: install the classic Windows iTunes package from Apple so its Apple Mobile Device Service is available, then install the separately licensed upstream device service:

```powershell
python -m pip install -U pymobiledevice3
npm ci
.
scripts\build-zsign-windows.ps1
npm run build --workspace @dreyzestore/windows-companion
cargo test --manifest-path apps/windows-companion/src-tauri/Cargo.toml
npm run tauri --workspace @dreyzestore/windows-companion -- build
```

The Tauri build creates unsigned NSIS and MSI packages under `apps/windows-companion/src-tauri/target/release/bundle/`. Windows signing credentials are intentionally absent. An unsigned development package will produce a Windows SmartScreen warning.

The `0.9.0 RC1` CI run uploads the unsigned NSIS/MSI installers with a sibling `SHA256SUMS.txt`. Windows installer metadata uses the MSI-compatible numeric prerelease `0.9.0-1`; the Companion displays `0.9.0 RC1`. The same run builds the DreyzeStore app bundle archive for inspection, `DreyzeStore-RC-device-test.ipa` (client built with the explicit test ID `org.dreyzestore.test.store`), and a generated sample app IPA. The Windows Companion accepts the test-bundle app through its existing authorized test-install flow. Verify artifact Actions provenance and the SHA-256 manifest before opening it. The test-bundle IPA is not a production package and does not use the eventual public bundle identifier.

The current `pymobiledevice3` Windows documentation recommends the classic iTunes installer because it supplies the Apple Mobile Device Service used for USBMux; the Microsoft Store Apple Devices package is not the supported substitute for that documented Windows path. Install instructions and current platform notes are in the [upstream installation guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/installation.md).

## Pairing and local API

The companion binds only to a selected private interface address. It creates a local self-signed TLS certificate; its SHA-256 fingerprint is displayed in the pairing QR and pinned by iOS. Pairing codes expire after two minutes and are one-use. After pairing, the iPhone stores the random bearer token in Keychain and Windows stores only its SHA-256 hash in Windows Credential Manager. Every authenticated call includes a short timestamp and unique nonce; replayed nonces are rejected.

The local API uses `/api/v1/device`, `/signing`, `/install`, `/install/{id}`, `/apps`, `/uninstall`, and `/refresh`. Every route except the one-time pair endpoint requires the paired token, the client UUID bound during pairing, a fresh timestamp, and unused nonce. The network server never accepts a package path or arbitrary URL from iPhone; the package arrives as a streamed request body with a UUID request ID and bounded metadata header.

## Device and package behavior

`pymobiledevice3 usbmux list --usb` performs the host lockdown handshake without automatically pairing a new device. Only devices for which the service returns a short device record are treated as trusted. App inventory comes from `pymobiledevice3 apps list --type User`; install and uninstall use the upstream `apps install` and `apps uninstall` commands with an explicit UDID. DreyzeStore confirms installs and removals by reading inventory again. Inventory includes the actual signed bundle ID and device-reported version/build. A record is `companionConfirmed` only when it exactly matches DreyzeStore's local installation record for that selected UDID; unknown apps are not promoted to Installed.

The service does not currently expose Developer Mode through its device short-info response. Companion labels this status unknown and requires the owner to enable it manually. If Developer Mode is off, device install fails; DreyzeStore never changes this setting automatically.

## Apple signing onboarding and readiness

The Apple Signing page now offers an **experimental local Apple Account path** and an advanced import fallback. The account path uses pinned upstream `isideload` 0.4.0 for reverse-engineered Apple authentication, 2FA, team discovery, explicit device registration, local certificate reuse/creation, per-app App ID/profile provisioning, and signing. Apple documents Personal Team provisioning through Xcode; it does not document or support this Windows path. Real Apple authentication/provisioning has not been tested in this phase.

Apple password is sent only through the local sign-in call and is not persisted. A one-time verification code is not saved. Apple session/ADSID, Anisette state, provider URL, and local signing key use Windows Credential Manager. A user-selected HTTPS Anisette operator receives Anisette/ADI protocol data, not Apple credentials as passed by DreyzeStore. The UI requires trust confirmation and explains that boundary. Sign out clears the session and associated local account/device status, but does not revoke certificates or delete signing keys. See [Apple auth security](apple-auth-security.md) and [Anisette](anisette.md).

On the automatic path, the user explicitly registers the connected iPhone. The signer maps bundle IDs to `<original>.<team ID>`, provisions App IDs/profiles per package, and checks the returned team's app identifier, registered UDID, certificate presence, and profile expiry before installation. It never automatically revokes certificates when a team limit is reached. Extensions, watch apps, App Clips, universal/fat binaries, DER entitlements, symbolic links, and unsupported capabilities fail closed; upstream itself marks full entitlement handling unfinished.

The advanced path imports the user's own Apple Development `.p12` and matching `.mobileprovision`. P12/profile data is protected locally, Windows CryptoAPI reads the P12 with `PKCS12_NO_PERSIST_KEY`, and the P12 password is stored in Windows Credential Manager. Both routes feed the same signing/install/inventory confirmation coordinator.

**Run Diagnostics** checks Apple Mobile Device Service state, the real `pymobiledevice3 usbmux list --usb` operation, a visible/trusted USB device, the reported Developer Mode state, P12/profile status, the profile's match for the connected phone, and whether a DreyzeStore pairing token is configured. USB and Trust show **Unknown** if no trusted device is returned because the current USBMux discovery cannot distinguish a disconnected phone from one awaiting the user's Trust action. Developer Mode remains **Unknown** when the provider does not expose it. Pairing check means a token is configured; it does not prove the phone is currently reachable.

**Test Installation** is a real local hardware test action, not a success mock. It accepts only a user-selected IPA with bundle ID prefix `org.dreyzestore.test.`, revalidates its archive and SHA-256, signs it with the ready automatic provider or imported files, installs through the same coordinator, and confirms exact signed bundle ID/version/build from device inventory. It never replaces a bundle already present outside its own test record. The dedicated uninstall action is restricted to that test record and clears it only after inventory confirms removal. Test package bytes are not copied to the repository or cloud. See [physical iPhone install test](physical-device-install-test.md).

The CI-generated `DreyzeStore-RC-device-test.ipa` is the DreyzeStore client source built under the test-only bundle ID `org.dreyzestore.test.store`; the app display name is **DreyzeStore RC**. It can exercise onboarding, pairing, and client/Companion behavior on a real iPhone. The checked-in Release API base URL is deliberately `.invalid`, so this artifact cannot load a live catalog until an operator builds it with an approved HTTPS API endpoint. A separate minimal `DreyzeDeviceTest-sample.ipa` is also produced to isolate device-service testing from store UI behavior.

The Companion is a foreground desktop app. This RC does not install a hidden background service, system-tray agent, or Windows autostart entry; the user starts it explicitly when pairing/installing. Apple signing and device dependencies remain locally configured.

The experimental Apple Account path supports local login, one-time 2FA, team discovery/selection, explicit device registration, local certificate reuse/creation, and per-app ID/profile provisioning through pinned upstream `isideload`. Live Apple acceptance is **NOT TESTED**. Arbitrary entitlement remapping is not supported; extensions, universal binaries, DER entitlements and capabilities outside the narrow allowlist fail closed. Automatic/background refresh and paid-team API-key onboarding are not implemented. See [Apple signing research](apple-signing.md), [provisioning details](apple-account-provisioning.md), and [Anisette privacy](anisette.md).

After a confirmed install, Companion retains the original, digest-named IPA for local refresh and removes failed temporary uploads. On next start it clears interrupted staging/signing data and unreferenced originals. Refresh reinstalls the saved, same-version package and confirms the refreshed profile through a new live inventory read. The iOS update flow obtains only published releases from the public API, downloads and verifies them with the Phase 4 pipeline, then sends the resulting `VerifiedPackage` through this same local validation/sign/install path. See [updates](updates.md) and [refresh](refresh.md).

## Licensing

The zsign source is MIT-licensed and built at the pinned upstream revision with the project-local password-stdin and post-sign-failure patches. Its Windows build links the included OpenSSL 3.4.0 (Apache-2.0) and zlib 1.3.1. License texts ship in the app's `licenses` resources. `pymobiledevice3` is GPL-3.0 and is installed by the operator rather than bundled or modified; see [third-party notices](../apps/windows-companion/src-tauri/licenses/THIRD_PARTY_NOTICES.txt).

No TrollStore, CoreTrust exploit, jailbreak helper, private installation API, leaked certificate, Apple password, or cloud signing service is part of this path.

## References

- [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/)
- [pymobiledevice3 Windows installation notes](https://github.com/doronz88/pymobiledevice3/blob/master/docs/installation.md)
- [pymobiledevice3 app commands](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/apps.py)
- [zsign pinned upstream revision](https://github.com/zhlynn/zsign/tree/614caa8d1ca949e260e5746144aa52d27a4b08d6)
