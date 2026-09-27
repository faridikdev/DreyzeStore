# Windows Companion

DreyzeStore Windows Companion is a local Windows 11 desktop app for the stock-iOS installation path. It accepts only a `VerifiedPackage` transfer from a paired iPhone, validates the IPA again, checks a locally imported Apple Development identity and provisioning profile, signs with the pinned zsign build, sends the signed package to the explicitly selected trusted iPhone, and reports `Installed` only after the iPhone's app inventory contains the exact bundle ID, version, and build.

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

The current `pymobiledevice3` Windows documentation recommends the classic iTunes installer because it supplies the Apple Mobile Device Service used for USBMux; the Microsoft Store Apple Devices package is not the supported substitute for that documented Windows path. Install instructions and current platform notes are in the [upstream installation guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/installation.md).

## Pairing and local API

The companion binds only to a selected private interface address. It creates a local self-signed TLS certificate; its SHA-256 fingerprint is displayed in the pairing QR and pinned by iOS. Pairing codes expire after two minutes and are one-use. After pairing, the iPhone stores the random bearer token in Keychain and Windows stores only its SHA-256 hash in Windows Credential Manager. Every authenticated call includes a short timestamp and unique nonce; replayed nonces are rejected.

The local API uses `/api/v1/device`, `/signing`, `/install`, `/install/{id}`, `/apps`, `/uninstall`, and `/refresh`. Every route except the one-time pair endpoint requires the paired token, the client UUID bound during pairing, a fresh timestamp, and unused nonce. The network server never accepts a package path or arbitrary URL from iPhone; the package arrives as a streamed request body with a UUID request ID and bounded metadata header.

## Device and package behavior

`pymobiledevice3 usbmux list --usb` performs the host lockdown handshake without automatically pairing a new device. Only devices for which the service returns a short device record are treated as trusted. App inventory comes from `pymobiledevice3 apps list --type User`; install and uninstall use the upstream `apps install` and `apps uninstall` commands with an explicit UDID. DreyzeStore confirms installs and removals by reading inventory again.

The service does not currently expose Developer Mode through its device short-info response. Companion labels this status unknown and requires the owner to enable it manually. If Developer Mode is off, device install fails; DreyzeStore never changes this setting automatically.

After a confirmed install, Companion retains the original, digest-named IPA for local refresh and removes failed temporary uploads. On next start it clears interrupted staging/signing data and unreferenced originals. Refresh reinstalls the saved, same-version package. New-version update selection belongs to PHASE 7.

## Licensing

The zsign source is MIT-licensed and built at the pinned upstream revision with the project-local password-stdin and post-sign-failure patches. Its Windows build links the included OpenSSL 3.4.0 (Apache-2.0) and zlib 1.3.1. License texts ship in the app's `licenses` resources. `pymobiledevice3` is GPL-3.0 and is installed by the operator rather than bundled or modified; see [third-party notices](../apps/windows-companion/src-tauri/licenses/THIRD_PARTY_NOTICES.txt).

No TrollStore, CoreTrust exploit, jailbreak helper, private installation API, leaked certificate, Apple password, or cloud signing service is part of this path.

## References

- [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/)
- [pymobiledevice3 Windows installation notes](https://github.com/doronz88/pymobiledevice3/blob/master/docs/installation.md)
- [pymobiledevice3 app commands](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/apps.py)
- [zsign pinned upstream revision](https://github.com/zhlynn/zsign/tree/614caa8d1ca949e260e5746144aa52d27a4b08d6)
