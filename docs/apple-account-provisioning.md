# Apple Account provisioning from Windows

## Status

The Companion now contains an **experimental local protocol integration** using pinned upstream `isideload` 0.4.0. The integration is implemented in Rust and exposed through the Signing page. It has not been tested against a live Apple Account or physical iPhone in this phase. A successful mock/unit build does not show that Apple accepts the account, team, certificate, App ID, profile, signature, or installation.

Apple's documented Personal Team workflow is managed through Xcode. Apple does not document a Windows Personal Team provisioning API. This implementation uses a reverse-engineered protocol and can stop working when Apple changes server behavior. It is an optional route for a user who chooses that risk; importing user-owned signing files remains available as an advanced fallback.

## Local flow

1. Connect and trust the iPhone over USB. Check Developer Mode directly on the device.
2. Enter the Apple Account in DreyzeStore Companion. The Rust process uses the pinned upstream library to authenticate with Apple. Password input is cleared from the UI as soon as the request starts and held in a zeroizing Rust value during the initial request; the password is not saved.
3. If Apple requests verification, enter the one-use code. The code is not persisted. The upstream library may also request trusted-device approval or an SMS resend.
4. The Companion fetches the account's development teams. A single team is selected automatically; otherwise the user chooses one.
5. The user confirms registering the currently connected iPhone. The Companion calls Apple's device-registration operation and only records the UDID locally after Apple returns success.
6. **Prepare signing** reuses or creates a local Apple Development identity. At the maximum certificate limit, the flow fails; DreyzeStore never automatically revokes a certificate.
7. For an authorized IPA, the existing Companion install coordinator revalidates the package. The pinned signer derives the stable bundle ID as `<original bundle ID>.<team ID>`, creates/reuses the App ID and profile, signs locally, validates the returned profile claims, and installs through the existing device service.
8. The Companion reports installed only after a fresh device inventory reports the signed bundle ID, version, and build.

The automatic signer currently accepts only a narrow package shape: one top-level `.app`, no app extensions/watch apps/App Clips, no universal/fat Mach-O, no DER entitlements, no symbolic links, and no entitlement keys outside the local allowlist. It fails closed outside that envelope. The upstream `isideload` README itself marks complete entitlement handling as unfinished. The iOS device remains the final signature/profile authority.

Profile expiry, team, app identifier, device allowlist, and certificate expiry are checked before the Companion returns a `SignedPackage`. Expiry is also recorded in the installation result. This path does not currently expose a separately managed App ID/profile editor or guarantee that every Apple capability can be provisioned.

## What is and is not supported

| Environment | Mechanism | Needs signing? | Can attempt install? | Can confirm? | Limits |
|---|---|---:|---:|---:|---|
| Standard iOS + Windows Companion | Local Apple Account protocol integration | Yes | Yes, after Apple provisioning | Yes, via live inventory | Experimental, not Apple-supported, not live-tested in this phase |
| Standard iOS + imported files | Existing local `.p12` + `.mobileprovision` flow | Yes | Yes | Yes, via live inventory | Files must belong to the user/team and match the app/device |
| Personal Team | Same experimental local protocol integration | Yes | Intended; not verified with a real account/device here | Only after live inventory | Apple controls account limits, profile lifetimes, and acceptance; consult current Apple docs |
| TrollStore / jailbreak | Not part of this provisioning path | N/A | No | No | Separate earlier handoff remains `Handed Off`, never an install confirmation |

## Apple bootstrap app

The CI iOS build remains unsigned. For the first physical test, build or select an authorized app IPA and use the Companion's test-install route for the reserved `org.dreyzestore.test.*` identifier. A later DreyzeStore install uses the normal paired `VerifiedPackage` path. Do not treat the generated test artifact as an Apple-signed build.

## Sources

- [Apple developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple: run on a physical device](https://developer.apple.com/documentation/xcode/running-your-app-on-a-simulated-or-physical-devices)
- [Apple: enable Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple provisioning profile and entitlements, TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Pinned `isideload` source at commit `52b504c2cd706a9e415109b0be9e137168034f5e`](https://github.com/nab138/isideload/tree/52b504c2cd706a9e415109b0be9e137168034f5e)
- [Pinned `iloader` upstream project](https://github.com/nab138/iloader)
- [SideStore upstream license and architecture](https://github.com/SideStore/SideStore)
