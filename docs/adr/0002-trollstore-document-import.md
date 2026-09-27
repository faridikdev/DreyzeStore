# ADR 0002: TrollStore document import handoff

- **Status:** Accepted for Phase 5.5 prototype; physical-device behavior remains unverified.
- **Date:** 2026-09-27
- **Scope:** iOS installation handoff from a Phase 4 `VerifiedPackage` to an installed TrollStore or TrollStore Lite receiver.

## Context

ADR 0001 correctly rejected direct private-helper integration and using TrollStore's `apple-magnifier` URL scheme as a local package receiver. Phase 5.5 rechecked the current upstream sources and found an additional public import surface: upstream TrollStore and TrollStore Lite register the `com.apple.itunes.ipa` document type and handle imported `.ipa` file URLs in their scene delegate.

## Decision

- Use Apple's public `UIDocumentInteractionController` Open In menu with the upstream-registered `com.apple.itunes.ipa` UTI.
- Pass only the original PackageStorage-managed URL from a `VerifiedPackage` after `InstallationCoordinator` has revalidated its receipt, digest, archive, and metadata.
- Let iOS list compatible installed document handlers and let the user select the destination. Do not probe `apple-magnifier`, private APIs, or jailbreak state.
- TrollStore/TrollStore Lite own the final Install/Cancel prompt and installation operation. DreyzeStore records the `didEndSendingToApplication` result as `Handed Off`, with the receiver bundle ID when provided; this callback does not confirm installation.
- Preserve the generic system share handoff as a separate fallback.
- Do not copy TrollStore code or build a jailbreak target solely for this document-import route. Keep direct Lite helper use and local developer signing outside the normal iOS target until separately designed and tested.

## Alternatives considered

| Alternative | Decision |
|---|---|
| `apple-magnifier://install?url=` | Rejected for local packages: upstream implements a remote HTTPS download path, can open Magnifier when TrollStore is absent, and cannot reuse the already SHA-256-verified local file. |
| `canOpenURL` probing | Rejected: the scheme intentionally collides with Magnifier and is not a reliable presence signal. |
| Direct helper/private MobileInstallation calls from DreyzeStore | Rejected: required entitlements/private frameworks are unavailable to the standard sandbox and would bypass the supported external confirmation boundary. |
| TrollStore Lite direct helper integration | Deferred: Lite uses jailbreak-only privileges, private frameworks, Theos packaging, a separate root helper, and jailbreak-provided `ldid`; it is unnecessary to use Lite's registered document receiver. |
| Generic activity/share sheet only | Kept as fallback, while Open In better filters the receiver list by IPA document type and supplies the documented receiver callback. |

## Consequences

- Compatible devices with TrollStore/TrollStore Lite installed can proceed from a DreyzeStore-verified package into the receiver's own install flow.
- The app can identify which app received the file, but cannot learn whether the user later cancelled, the receiver rejected the package, or installation succeeded.
- `.available` on this backend means the public Open In handoff action is implemented. It does not mean a TrollStore receiver is installed; iOS determines the receiver list at runtime.
- A receiving document handler other than TrollStore may appear. The UI identifies the actual bundle ID and never attributes an unknown handler to TrollStore.
- The user report in upstream issue #957 is recorded as a compatibility risk; physical device testing remains necessary.

## References

- [TrollStore Info.plist at reviewed upstream revision](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStore/Resources/Info.plist)
- [TrollStore Lite Info.plist at reviewed upstream revision](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStoreLite/Resources/Info.plist)
- [TrollStore scene delegate](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStore/TSSceneDelegate.m)
- [TrollStore installation controller](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/TrollStore/TSInstallationController.m)
- [Apple UIDocumentInteractionController](https://developer.apple.com/documentation/uikit/uidocumentinteractioncontroller)
- [Apple receiver callback and bundle-ID semantics](https://developer.apple.com/documentation/uikit/uidocumentinteractioncontrollerdelegate/documentinteractioncontroller%28_%3Adidendsendingtoapplication%3A%29)
- [Upstream issue #957](https://github.com/opa334/TrollStore/issues/957)
