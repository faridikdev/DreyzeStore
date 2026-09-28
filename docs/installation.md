# Installation architecture and research

**Current status (0.9.0 RC1 / Phase 8.5):** The stock-iOS path is the Windows Companion flow documented in [windows-companion.md](windows-companion.md). The client pairs to a local Windows app, transfers its Phase 4 `VerifiedPackage`, and Windows independently revalidates, signs with either the experimental local Apple Account provider or user-imported Apple Development identity/profile, installs through the paired USB device service, and reads app inventory before returning `Installed`. The Apple Account protocol is reverse-engineered, unofficial, and has not been tested against a live account. A CI-generated DreyzeStore RC device-test IPA uses the reserved `org.dreyzestore.test.store` identity and still goes through the Companion's user-selected test package path. The physical iPhone/signing flow remains **NOT VERIFIED**. Simulator or mock-device tests do not prove device installation.

The Phase 5.5 TrollStore document-import route remains a separate optional handoff for a compatible environment where TrollStore is already installed. It is not the stock iOS 26 installation mechanism and reports **Handed Off**, never **Installed**. No TrollStore/CoreTrust or jailbreak implementation is included in the standard iOS app.

| Environment | Mechanism in DreyzeStore | Installs? | What DreyzeStore can confirm |
|---|---|---:|---|
| Stock sandboxed iOS 26 + paired Windows Companion | Local pinned TLS transfer; Windows validates, signs and calls device installation service over trusted USB | Yes, with a valid local identity/profile and compatible package/device | Exact bundle ID/version/build appears in device inventory after install |
| Compatible legacy environment with TrollStore | Apple document Open In to TrollStore | TrollStore may install after its own confirmation | Handoff only |
| Standard sandboxed iOS without Companion | No arbitrary IPA installation API | No | Downloaded and verified package only |

Windows Companion can create/reuse local signing material and provision a device/app/profile through the experimental Apple Account protocol integration, or accept user-imported files. It never uploads Apple credentials to the catalog backend. Automatic setup remains unverified against live Apple services. Consult [Apple signing constraints](apple-signing.md) and the [physical-device test plan](physical-device-install-test.md).

`VerifiedPackage` is the only input accepted by `InstallationBackend`. Before handoff, `InstallationCoordinator` asks `PackageValidator` to verify the PackageStorage receipt, file location, SHA-256, archive structure, release metadata, bundle ID, version, build, and minimum OS again. No arbitrary URL or server-only release model can enter the handoff route. No TrollStore source or exploit code is copied into this repository.

## Findings from current upstream TrollStore

Research was checked against upstream `opa334/TrollStore` commit [`88424f683b2a08f34a3f88985f790f97d84ce1df`](https://github.com/opa334/TrollStore/tree/88424f683b2a08f34a3f88985f790f97d84ce1df) on 2026-09-27.

- TrollStore and TrollStore Lite both register the imported document type `com.apple.itunes.ipa` for `.ipa` files in `CFBundleDocumentTypes` ([TrollStore Info.plist](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStore/Resources/Info.plist), [Lite Info.plist](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStoreLite/Resources/Info.plist)).
- Upstream `TSSceneDelegate` receives an imported file URL, starts security-scoped access, routes `.ipa`/`.tipa` to `TSInstallationController.presentInstallationAlertIfEnabledForFile`, and releases the access when TrollStore's operation callback finishes ([scene delegate](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStore/TSSceneDelegate.m)). The controller reads package metadata, shows the user an Install/Cancel prompt when enabled, and invokes TrollStore's install routine after the user selects Install ([installation controller](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStore/TSInstallationController.m)). This is a real target-side installation flow, not a DreyzeStore installation API.
- Apple's public `UIDocumentInteractionController.presentOpenInMenu` presents compatible document handlers for the supplied URL/UTI. Apple provides `willBeginSendingToApplication` and `didEndSendingToApplication` callbacks; the latter identifies the receiving app, and neither reports what that app did after it received the file ([API overview](https://developer.apple.com/documentation/uikit/uidocumentinteractioncontroller), [delegate callback](https://developer.apple.com/documentation/uikit/uidocumentinteractioncontrollerdelegate/documentinteractioncontroller%28_%3Adidendsendingtoapplication%3A%29)). DreyzeStore uses this Open In menu with `com.apple.itunes.ipa`, then recognizes TrollStore's or TrollStore Lite's bundle ID in the callback when the OS returns it.
- The `apple-magnifier://install?url=...` scheme is a remote-URL downloader in TrollStore, not a local verified-file import API. Upstream states that without TrollStore the system Magnifier app opens. DreyzeStore does not use that scheme to detect TrollStore or to bypass its local SHA-256-verified file.
- An open upstream issue reported a file-picker/share failure in a restored TrollStore Lite environment in September 2026 ([issue #957](https://github.com/opa334/TrollStore/issues/957)). It is an environment-specific report rather than a published API restriction, but it reinforces the need for physical-device testing.
- Upstream README support is limited to iOS 14.0 beta 2–16.6.1, the specific 16.7 RC build 20H18, and iOS 17.0. It excludes other 16.7.x builds and iOS 17.0.1+ ([README](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/README.md)). DreyzeStore does not extend or infer this compatibility list.

The supported integration surface found here is **document import through Open In**. No TrollStore URL-scheme callback, public helper API, or entitlement-granting route exists for a normal sandboxed client to call an install routine directly. The receiving app owns the confirmation and install result.

## DreyzeStore prototype

`TrollStoreBackend` accepts only a `VerifiedPackage` and requests a document handoff. `TrollStoreDocumentImportSheet` gives the already revalidated app-managed IPA to `UIDocumentInteractionController`, declares `com.apple.itunes.ipa`, and displays Apple's Open In menu. It does not copy TrollStore internals or attempt private helper communication.

The receiving app is selected at runtime. If TrollStore or TrollStore Lite is installed and registered for the IPA UTI, it can appear in the menu. The user selects it, TrollStore presents its own confirmation, and TrollStore installs only after that confirmation. The `didEndSendingToApplication` callback lets DreyzeStore record the receiving bundle ID; DreyzeStore records **Handed Off** and cannot observe the subsequent prompt, cancellation, or installation result. A selected application in the callback is never interpreted as installed.

The system Open In API is considered an available *handoff action* in this build, not proof TrollStore is installed. If the menu has no compatible receiver, DreyzeStore returns a clear error. The fallback External App Handoff remains available as a separate system share-sheet action.

## TrollStore Lite and jailbreak build feasibility

TrollStore Lite is a distinct upstream application intended for jailbroken iOS environments. It can receive `.ipa` files through the same registered UTI and document import flow. Its actual installation work is performed inside Lite, not inside DreyzeStore.

The upstream Lite Makefile builds an arm64 iOS app from the TrollStore and shared Objective-C sources using Theos, links private `Preferences`, `MobileIcons`, and `MobileContainerManager` frameworks, and sets `TROLLSTORE_LITE`. The upstream root helper has a separate `trollstorehelper_lite` build with `TROLLSTORE_LITE` and `DISABLE_SIGNING`; Lite expects a jailbreak-provided `ldid` at its jailbreak-root path. Lite's app/helper entitlements include unsandboxed/platform-application access and private MobileInstallation, container manager, Launch Services, SpringBoard, and uninstall privileges ([Lite app entitlements](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStoreLite/entitlements.plist), [root helper Makefile](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/RootHelper/Makefile), [root helper entitlements](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/RootHelper/entitlements.plist)). These privileges are not available to a normal signed/sandboxed iOS app.

A future `DreyzeStore-Jailbreak` target is technically possible as a separate jailbreak-specific product using shared SwiftUI/store and verification modules plus a separately packaged, environment-specific helper. It would require an explicitly supported jailbreak/toolchain matrix, Theos packaging, rootful/rootless variants, privileged entitlements supplied by the jailbreak environment, and device tests on each supported bootstrap. It must not compile those private APIs or helper into the normal target. It is not required for this prototype: the public document-import path can hand off to an already installed Lite app without DreyzeStore taking its privileges. No jailbreak target or privileged helper is included now.

## Developer signing path

No fake signer is implemented. A realistic local flow is:

```text
VerifiedPackage
    -> local macOS helper revalidates the source receipt and digest
    -> signs only with the user's locally managed certificate/private key and provisioning profile
    -> emits a distinct locally signed IPA and a new local digest/receipt
    -> installs to a registered, paired iPhone using Xcode or Apple Configurator 2
```

Apple's supported registered-device workflow requires an App ID, a signing certificate and private key, a registered device, and a provisioning profile. Apple documents installing the exported IPA with Xcode or Apple Configurator 2, and requires Developer Mode on each device running an IPA-based app ([Apple Xcode guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices), [development profile requirements](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)). Signing material should remain in the user's macOS Keychain; Apple describes private keys as part of the local signing identity ([Keychain Services](https://developer.apple.com/documentation/security/keychain-services)).

This path is scoped to registered development/test devices, not a universal consumer IPA store. Entitlements, App IDs, extensions, embedded frameworks, and provisioning profiles can prevent a third-party IPA from being re-signed or launched. A helper must preserve the original verified receipt and produce a separate signed-artifact receipt; the source SHA-256 must never be presented as the digest of the modified package. Apple credentials are never sent to DreyzeStore servers. Windows cannot run Xcode or Apple Configurator 2; a Windows UI could at most orchestrate an explicitly paired Mac helper. No signing or device-install code is present in this phase.

## Capability matrix

“Can confirm?” distinguishes what the target tool can do from what DreyzeStore can observe. Inventory and uninstall columns mean **available to DreyzeStore**, not merely inside another manager's own UI.

| Environment | Installation mechanism | Needs Apple developer signing? | Needs jailbreak? | Can install? | Target can confirm? | DreyzeStore can confirm? | Inventory to DreyzeStore? | Uninstall from DreyzeStore? |
|---|---|---:|---:|---|---|---|---|---|
| Standard sandboxed iOS | Public Open In/share handoff only | Depends on receiving app; no install capability in DreyzeStore | No | No, only hand off | Receiving app controls its own result | No | No | No |
| TrollStore-compatible iOS with TrollStore installed | Open In sends the verified IPA to TrollStore; TrollStore's own prompt/helper installs it | No | No | Yes, after user confirms in TrollStore | Yes, inside TrollStore | No; DreyzeStore receives only the document-send callback | No | No; use TrollStore's own manager |
| Jailbroken iOS with TrollStore Lite installed | Open In sends the IPA to Lite; Lite uses its jailbreak-provided privileged helper | No Apple signing; Lite relies on its jailbreak environment and `ldid` | Yes | Yes, after user confirms in Lite | Yes, inside Lite | No; DreyzeStore receives only the document-send callback | No | No; use Lite's own manager |
| Developer signing environment | Future local signer then Xcode/Apple Configurator on a paired Mac | Yes: certificate, private key, App ID, registered device/profile | No | Yes for supported registered test devices, once implemented | Xcode/Configurator reports its own operation | No in this phase | No | No in this phase |
| External handoff only | iOS share sheet to an app chosen by the user | Depends on recipient; no signer in DreyzeStore | No | Not by DreyzeStore | Recipient may show its own result | Only file/activity handoff, not install | No | No |

TrollStore and Lite can install in their own processes after user confirmation. **DreyzeStore currently does not have an authoritative installed result, inventory, or uninstall capability on any row.**

## Installation security boundary

- The only install/handoff input is `VerifiedPackage`, constructed after Phase 4 checksum and archive checks.
- `InstallationCoordinator` revalidates the package's PackageStorage receipt, managed path, SHA-256, archive structure, and IPA metadata immediately before calling the selected backend.
- TrollStore Open In receives that verified managed file. If the file changes or leaves PackageStorage, the coordinator stops before presenting any handoff UI.
- The receiving bundle ID is retained only as a handoff destination. It is not proof of package acceptance or installation.
- There is no “Install Anyway” checksum bypass, no DreyzeStore private framework call, and no exploit code.
- A matching checksum proves only that downloaded bytes match the repository's published digest. It does not prove the app is benign, its publisher is trustworthy, or that iOS will accept its signature.

## Upstream license review

No upstream TrollStore code or binary is included. The upstream repository license identifies the project as MIT except `RootHelper/uicache.m`, which has a separate BSD-4-Clause notice ([license](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/LICENSE)). If a future phase copies or redistributes any upstream component, review that exact file and preserve its copyright and license notices.
