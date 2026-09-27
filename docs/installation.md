# Installation architecture

**Status:** Phase 1 foundation. DreyzeStore will not ship a backend that reports success without a verifiable installation result. `InstallationBackend` is an interface only; no concrete backend is registered or implemented.

In Phase 1, `VerifiedPackage` has an internal initializer so future installation code can require a value produced by verification. The verifier is deferred to Phase 4. No TrollStore or TrollStore Lite source has been downloaded or copied into this repository. The current tab shell exposes no install action.

## What the iOS app can and cannot do

The iOS client can use `URLSession` to download an IPA into a temporary app-container location, verify its published SHA-256, and inspect its ZIP/IPA metadata. A normal sandboxed app cannot call a public Apple API to install arbitrary IPA files, replace system package-management services, or enumerate all third-party installed apps. Installation and installed-app discovery are conditional capabilities, not baseline features of an App Store-style SwiftUI view.

The UI uses these separate states:

```text
GET -> Downloading -> Verifying -> Preparing handoff ->
  Installed (only on backend confirmation)
  Handed off (external app/system owns the next step)
  Unavailable (no supported method)
  Failed / Cancelled
```

`Handed off` is not `Installed`. The download can still be a useful, verified, cancellable file when no install route exists. The UI explains the actual next step and does not offer an inactive Install button.

## Backend contract

The device capability service combines runtime OS availability, the app's actual entitlements, explicit user configuration where required, and a backend-specific availability result. It does not infer private/jailbreak state from private APIs or from a generic `canOpenURL` result.

```swift
protocol InstallationBackend: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    func availability() async -> BackendAvailability
    func install(verifiedPackage: VerifiedPackage) async throws -> InstallationResult
    func uninstall(bundleIdentifier: String) async throws -> UninstallationResult
}

enum InstallationResult: Sendable {
    case installed(InstalledApplication) // backend has an authoritative result
    case handedOff(ExternalHandoff)      // user/system/external app must finish
}
```

`BackendAvailability` is one of `available`, `requiresUserAction`, `unavailable`, or `unknown`, plus a user-facing explanation and a technical reason code. The registry only shows actions appropriate to that state. The API can be adjusted to preserve Apple's actual lifecycle result; it must not collapse a handoff into success.

The package passed to a backend is a value created only after checksum and archive validation. Installation backends do not accept an arbitrary URL as proof that a package has been verified.

## Upstream TrollStore findings

The official [opa334/TrollStore README](https://github.com/opa334/TrollStore/blob/main/README.md) describes TrollStore as a permanently signing jailed app relying on an AMFI/CoreTrust signature-verification bug. Its published support list is iOS 14.0 beta 2 through 16.6.1, the specific 16.7 RC build 20H18, and 17.0. The upstream README explicitly excludes 16.7.x other than that RC and 17.0.1 or later. DreyzeStore will not extend that list or promise permanent signing on other versions.

Upstream documents the URL handoff `apple-magnifier://install?url=<URL_to_IPA>`. It replaces the system `apple-magnifier` scheme; upstream says devices without TrollStore open Magnifier instead. This makes the scheme unsuitable as a reliable presence probe. Upstream documents a handoff, not a documented caller-visible installation result callback, so DreyzeStore can report only **Handed off** unless a future upstream-supported API provides confirmation.

TrollStore Lite is not a separate public SDK. Its [upstream build target](https://github.com/opa334/TrollStore/blob/main/TrollStoreLite/Makefile) compiles the same `TrollStore/*.m` and `Shared/*.m` sources with `TROLLSTORE_LITE`, links private frameworks, and builds a privileged helper. The [upstream helper](https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m) assumes `ldid` exists at a jailbreak-root path for Lite. It is an environment-specific TrollStore variant, not an API that an ordinary store app can embed or call on a stock device.

No TrollStore or TrollStore Lite source is copied, embedded, or represented as DreyzeStore code. Any future adapter remains isolated in `Installation/TrollStore/`, uses only a reviewed upstream-supported handoff, and preserves upstream license/copyright notices. It cannot bypass the host app's sandbox by ordinary Swift code.

## Backend matrix

| Method | Phase 0 decision | Honest client behavior |
|---|---|---|
| Apple alternative marketplace | The only first-party marketplace route that can install notarized third-party packages through OS marketplace APIs. Requires region/device compatibility, Apple's program eligibility, and the required entitlement/authorization. EU marketplace support begins at iOS 17.4; requirements and regions are Apple-controlled and can change. | Not shown as available until the client itself is signed with the correct approved entitlement and MarketplaceKit reports the supported route. A plain catalog app cannot self-grant that entitlement. |
| TrollStore | Optional future external handoff for devices with a compatible, already-installed TrollStore and supported OS environment. Supported versions are the upstream list above. | If deliberately configured, launch the upstream handoff only after verification. Mark `Handed off`; do not claim installation/uninstallation or installed-app inventory based only on `UIApplication.open`. |
| TrollStore Lite | Do not integrate into the store client. It is an upstream jailbreak-oriented build variant with private framework/helper assumptions, not a generic external installation service. | Unavailable in DreyzeStore unless a separately reviewed, upstream-supported public bridge appears. |
| Developer signing | Not a general IPA installation API in a sandboxed iPhone app. Signing/provisioning is an external developer workflow requiring appropriate credentials, provisioning, registered devices or an authorized distribution channel. | DreyzeStore may export/share a verified file or hand off to an explicitly configured companion. It cannot report install success until that system confirms it. No private signing keys go in the iOS app. |
| Enterprise, MDM, or web distribution | Valid only in the relevant managed/authorized distribution context and with correctly signed packages, profiles, domains, OS versions, and approvals. It is not a universal consumer install backend. | Implement as a separate OS/vendor-approved backend only after validating the exact supported installation API and result signal. |
| External installer | A generic adapter for an explicitly configured external app/system workflow. | A successful scheme handoff means only that control was handed off. No fake `Installed` state. |

Apple's official [alternative marketplace overview](https://developer.apple.com/support/alternative-app-marketplace-in-the-eu/) states that marketplace capabilities are region- and OS-limited and that operating a marketplace requires Apple's authorization. Its current EU criteria include two years of Apple Developer Program standing and more than one million first annual installs worldwide in the prior calendar year. The [MarketplaceKit documentation](https://developer.apple.com/documentation/marketplacekit/creating-an-alternative-app-marketplace) describes the required entitlement, Apple Developer Program relationship, website, server, and notarized app distribution package. This path is a possible future backend only if DreyzeStore's operator qualifies and receives Apple's authorization; it is not a free generic IPA-install API.

## Capability detection

`DeviceCapabilityService` reports observable facts only:

- OS version and public API availability.
- Whether DreyzeStore was built/signed with a required entitlement.
- Whether the relevant Apple framework returns an authorized capability.
- Whether an external route was explicitly selected/configured and can be opened.
- Backend-specific support state and the reason a method is absent.

It does not claim to prove TrollStore installation from a URL-scheme probe. It does not read a complete app inventory through undocumented LaunchServices/private APIs. Where the platform gives no supported detection signal, the backend remains `unknown` or `requiresUserAction`, not `available`.

An external URL handler's presence is not proof of the handler's identity or of a successful install. For the ambiguous `apple-magnifier` scheme, do not present a probe as automatic TrollStore detection; a user-selected handoff remains `requiresUserAction` and ends as `Handed off`.

Structural validation also does not prove that iOS will accept an IPA's code signature or provisioning profile. The selected, authorized installation backend and OS make that decision. DreyzeStore reports signature/install failures from that backend and does not claim the archive is installable solely because its metadata parsed.

## Download and validation boundary

1. Request a published release and expected byte size/SHA-256 from the selected repository.
2. Download with a cancellable background-compatible `URLSession` task to a unique temporary file. Resume data is optional and untrusted; verify the final file from byte zero.
3. Check available storage and exact size; calculate SHA-256 and compare in constant time where applicable. On mismatch, delete/quarantine the file and stop.
4. Inspect the ZIP central directory and expected `Payload/<single AppName>.app/Info.plist`; verify bundle identifier, version, executable path, declared size, entry count, compressed/uncompressed totals, and expansion limits.
5. Reject absolute paths, `..`, traversal after normalization, NULs, duplicate/conflicting paths, symlinks and special files, excessive nested paths, oversized entries, and zip-bomb ratios. Never extract outside a newly created, app-owned temporary directory. Prefer reading required entries without extracting the whole archive.
6. Create an immutable `VerifiedPackage` only after all checks pass. Clean up on cancellation, mismatch, expiration, and final handoff according to retention settings.
7. Call only the selected available backend. Record the backend's actual result type and preserve its explanation.

Archive parsing dependency selection is provisional: ZIPFoundation is MIT-licensed and is a candidate, but it must pass explicit security tests for the required limits before adoption. The validator must enforce its own path and resource limits instead of assuming a library's default extraction behavior is safe.

## Installed apps and updates

An unprivileged iOS client cannot promise an OS-wide installed-app scan. Store/library states therefore distinguish `Downloaded`, `Previously Installed`, and `Installed (reported by <backend>)`. Update comparison runs only for bundle IDs/versions the user or a supported backend actually reported. `GET /api/v1/updates` provides latest releases; it is not proof of local installation. Update All is enabled only for entries whose current backend can complete and report the update operation.

For Apple's authorized MarketplaceKit backend, use the documented marketplace lifecycle/result APIs and the app's entitlements. For external TrollStore/signing/MDM flows, retain the handoff state unless an upstream/OS callback supplies authoritative confirmation. No success message is shown just because an external app was opened.
