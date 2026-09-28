# Apple signing on Windows

## Status

Windows Companion has two paths:

1. **Experimental local Apple Account provisioning.** The Companion uses pinned upstream `isideload` to authenticate with Apple, handle a one-use 2FA challenge, discover teams, explicitly register a connected iPhone, create/reuse a local certificate, and provision/sign a narrow set of app packages. Apple does not document or support this Windows Personal Team flow. It has **not** been tested against a live Apple Account or physical iPhone in this phase.
2. **Import existing signing files.** The user can import their own Apple Development `.p12` and matching `.mobileprovision` as an advanced fallback. The password and files stay local.

The protocol path is real code, not a fake success handler. Its existence is not proof that Apple's live services will accept it. The Companion's install result is still based on live device inventory and never on a successful sign or handoff alone.

## Capability table

| Setup | Supported behavior | Required material / limitation |
|---|---|---|
| Free Personal Team | Experimental local protocol integration; not live-tested | No manual `.p12`/profile is intended, but automatic setup is not demonstrated. Apple's profile/device/app limits and lifetimes apply. |
| Paid Developer Program team | Same experimental Apple Account protocol, or import | No cloud signing. A live team test is not performed. |
| Existing team identity | Import `.p12` + `.mobileprovision` | Must authorize the app, certificate, device UDID and current date. |
| App Store Connect API key | Not implemented | Apple API is a separate local paid-team route; team keys have broad permissions and are not Apple Account passwords. |
| TrollStore / jailbreak | Not part of this provisioning flow | Separate earlier handoff remains `Handed Off`, never `Installed`. |

## Signing and provisioning boundary

The experimental path calls the upstream signer only after package validation and confirmed device registration. It uses a deterministic `<original bundle ID>.<team ID>` mapping. The signer creates/reuses the App ID and profile for that mapped identifier; Companion then checks signed metadata and the embedded profile's team, bundle ID, UDID and expiry. A mismatch blocks installation. The existing device install coordinator still confirms the exact signed bundle/version/build from a fresh inventory.

Automatic signing fails closed for extensions, watch apps, App Clips, universal/fat binaries, DER entitlements, symbolic links, and entitlements outside a narrow allowlist. Upstream `isideload` marks comprehensive entitlement handling as unfinished. Do not assume arbitrary third-party IPA support. The user remains responsible for distribution rights and must only install authorized packages.

The advanced import path continues to use the user's own `.p12` and profile. Imported bytes are locally protected; the password is stored in Windows Credential Manager. No certificate or private key is sent to DreyzeStore or an anisette service.

## Privacy

Apple email/password/2FA are entered in the Windows Companion and sent only through the local Apple-authentication implementation to Apple. The selected anisette operator receives Anisette protocol/ADI state, not those credential fields. Apple session token and ADSID, local signing key, profile/certificate metadata, and account state are stored on the Windows PC through Windows Credential Manager. See [Anisette](anisette.md), [Apple auth security](apple-auth-security.md), and the [threat model](../DreyzeStore-threat-model.md).

## Personal Team restrictions

Apple's own [developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) and [physical-device workflow](https://developer.apple.com/documentation/xcode/running-your-app-on-a-simulated-or-physical-devices) describe Xcode-managed development provisioning. The Companion does not bypass Apple's limits. The device owner must trust the PC, enable Developer Mode, and confirm device registration. Profile lifetime and account limits are controlled by Apple; consult Apple's current docs instead of relying on UI constants.

## Research and license gate

| Project/component | Pinned source | License metadata | Use |
|---|---|---|---|
| `isideload` 0.4.0 | `nab138/isideload`, commit `52b504c2cd706a9e415109b0be9e137168034f5e` | MIT | Linked as a Rust dependency; no upstream source copied into DreyzeStore |
| `isideload-apple-codesign` 0.29.11 | `nab138/isideload-apple-platform-rs`, commit `3100109c6a967375dec78f018be5f4a42cd1bdd9` | MPL-2.0 | Linked code-signing dependency; no source copied |
| `apple-codesign-quick` 0.1.0 | `Dadoum/apple-crates` | LGPL-2.1-or-later | Transitive static Rust dependency; distribution needs a relinking/source compliance review |
| SideStore | `SideStore/SideStore` upstream | AGPL-3.0 | Research only; no source linked or copied |
| iLoader | `nab138/iloader` upstream | MIT project, with its own branding/assets | Research only; no source or branding copied |

The app's Windows release bundle must include the required third-party notices and satisfy LGPL relinking/source obligations before distribution. The current phase creates no production release and does not add signing credentials. See [license notes](licenses.md).

## Sources

- [Apple developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple: run on physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-a-simulated-or-physical-devices)
- [Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple TN3125: provisioning profiles and entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Pinned `isideload` source](https://github.com/nab138/isideload/tree/52b504c2cd706a9e415109b0be9e137168034f5e)
- [Pinned `isideload-apple-codesign` source](https://github.com/nab138/isideload-apple-platform-rs/tree/3100109c6a967375dec78f018be5f4a42cd1bdd9)
- [SideStore source](https://github.com/SideStore/SideStore)
- [iLoader source](https://github.com/nab138/iloader)
