# Installation architecture

**Status:** Phase 5. DreyzeStore has a verified-package boundary and one real system-share handoff backend. It does not install an IPA on ordinary sandboxed iOS and never labels an external handoff as an installation.

`VerifiedPackage` can only be created by `PackageValidator` after the local file's digest matches release metadata and its IPA structure and app metadata validate. Immediately before a backend receives it, DreyzeStore confirms the file and sidecar record belong to `PackageStorage`, recomputes SHA-256, and reinspects IPA metadata. No TrollStore or TrollStore Lite source has been downloaded or copied into this repository.

## What the iOS app can and cannot do

The iOS client uses a background-compatible `URLSession` to download an IPA into a UUID-named app-managed temporary location, verify the published SHA-256, and inspect required ZIP/IPA metadata without extracting arbitrary archive paths. The verified file is retained in DreyzeStore's managed package directory. A normal sandboxed app cannot call a public Apple API to install arbitrary IPA files, replace system package-management services, or enumerate all third-party installed apps. Installation and installed-app discovery are conditional capabilities, not baseline features of an App Store-style SwiftUI view.

The download flow and installation flow use separate states:

```text
GET -> Downloading -> Verifying -> Inspecting -> Package Ready
Package Ready -> Preparing Installation -> Installing -> Handed Off
                                                        (system share activity completed)
```

`Package Ready` is not `Installed`. The system share sheet accepts the verified local IPA and returns whether a selected share activity completed. DreyzeStore records that as `Handed Off`; the receiving app's actual installation is outside its control and cannot be confirmed from this callback. Only a future backend with an authoritative result can emit `Installed`.

## Backend contract

The device capability service combines runtime OS availability, the app's actual entitlements, explicit user configuration where required, and a backend-specific availability result. It does not infer private/jailbreak state from private APIs or from a generic `canOpenURL` result.

```swift
protocol InstallationBackend: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var availability: BackendAvailability { get }
    var capabilities: InstallationCapabilities { get }

    func install(package: VerifiedPackage) async -> InstallationDirective
    func uninstall(bundleIdentifier: String) async -> UninstallationResult
    func queryInstalledState(bundleIdentifier: String) async -> InstalledState
}

enum BackendAvailability: Sendable {
    case available
    case unavailable(reason: String)
    case requiresConfiguration(reason: String)
    case unsupported(reason: String)
}
```

`InstallationCoordinator` is the only UI-facing route into a backend. It serializes state transitions, checks availability and capabilities, repeats package validation, and reports `installed`, `handedOff`, `cancelled`, `failed`, or `unsupported`. A `handoffRequested` directive is not success: the coordinator waits for the system activity controller's completion callback before recording `Handed Off`. Backend selection shows only `.available` methods. The settings screen also explains methods that are unavailable, unsupported, or need local configuration.

The protocol accepts only `VerifiedPackage`; no route accepts a URL or server-only release metadata. `PackageValidator.revalidateForInstallation` requires a matching app-managed sidecar and path and recomputes digest, size, archive structure, bundle ID, version/build, and minimum OS. The downloaded file stays inside app-managed storage. The coordinator stops before invoking any backend if those checks fail.

## Upstream TrollStore findings

The official [opa334/TrollStore README](https://github.com/opa334/TrollStore/blob/main/README.md) describes TrollStore as a permanently signing jailed app relying on an AMFI/CoreTrust signature-verification bug. Its published support list is iOS 14.0 beta 2 through 16.6.1, the specific 16.7 RC build 20H18, and 17.0. The upstream README explicitly excludes 16.7.x other than that RC and 17.0.1 or later. DreyzeStore will not extend that list or promise permanent signing on other versions.

Upstream documents the URL handoff `apple-magnifier://install?url=<URL_to_IPA>`. It replaces the system `apple-magnifier` scheme; upstream says devices without TrollStore open Magnifier instead. This makes the scheme unsuitable as a reliable presence probe. Upstream documents a handoff, not a documented caller-visible installation result callback, so DreyzeStore can report only **Handed off** unless a future upstream-supported API provides confirmation.

TrollStore Lite is not a separate public SDK. Its [upstream build target](https://github.com/opa334/TrollStore/blob/main/TrollStoreLite/Makefile) compiles the same `TrollStore/*.m` and `Shared/*.m` sources with `TROLLSTORE_LITE`, links private frameworks, and builds a privileged helper. The [upstream helper](https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m) assumes `ldid` exists at a jailbreak-root path for Lite. It is an environment-specific TrollStore variant, not an API that an ordinary store app can embed or call on a stock device.

No TrollStore or TrollStore Lite source is copied, embedded, or represented as DreyzeStore code. The upstream repository is MIT-licensed overall, with `RootHelper/uicache.m` separately under BSD-4-Clause; neither code nor binaries from those components are included. DreyzeStore's TrollStore entries are disabled backend descriptors, not an exploit or installer implementation.

## Backend matrix

| Backend | Environment | Install / handoff | Confirmation | Uninstall | Inventory |
|---|---|---|---|---|---|
| External App Handoff | Sandboxed iOS with the system share sheet | Shares only a revalidated, app-managed IPA URL | Reports `Handed Off` only when the selected activity completes; does not confirm installation | No | No |
| TrollStore | Compatible upstream-supported OS and TrollStore installed; not reliably detectable from this sandbox | Disabled. Upstream documents a URL handoff, but the local IPA is private to DreyzeStore's sandbox and is not shared with TrollStore | Not available; opening the scheme is not proof of TrollStore presence or install | No supported client API | No supported client API |
| TrollStore Lite | Jailbroken environment with the upstream privileged helper and private framework assumptions | Unsupported. DreyzeStore does not package or invoke the helper | None | None | None |
| Developer Signing | Local, user-configured signer and supported device installation workflow | Requires configuration. This phase does not sign packages or invoke a signer | No confirmation until a future supported backend provides it | None | None |
| Apple MarketplaceKit | Apple's approved marketplace program, entitlement, region, device, and notarized package requirements | Not implemented; the entitlement and operator approvals are not configured | Not implemented | Not implemented | Not implemented |
| Enterprise / MDM | Organization-managed devices and authorized distribution setup | Not implemented; not a generic consumer IPA API | Not implemented | Not implemented | Not implemented |

Only **External App Handoff** is currently shown as an available method. It shares the verified local package through Apple's `UIActivityViewController`; no external installer is detected or assumed. Apple documents the completion handler as the result of the selected activity or sheet dismissal, not the receiving app's install state ([UIActivityViewController](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller), [completion handler](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/completionwithitemshandler-swift.typealias)).

Apple's official [alternative marketplace overview](https://developer.apple.com/support/alternative-app-marketplace-in-the-eu/) states that marketplace capabilities are region- and OS-limited and that operating a marketplace requires Apple's authorization. Its current EU criteria include two years of Apple Developer Program standing and more than one million first annual installs worldwide in the prior calendar year. The [MarketplaceKit documentation](https://developer.apple.com/documentation/marketplacekit/creating-an-alternative-app-marketplace) describes the required entitlement, Apple Developer Program relationship, website, server, and notarized app distribution package. This path is a possible future backend only if DreyzeStore's operator qualifies and receives Apple's authorization; it is not a free generic IPA-install API.

## Capability detection

`DeviceCapabilityService` reports configured backend states and the public OS version only:

- OS version and public API availability.
- Whether a method in this build has an implemented, available public route.
- Whether a method requires explicit local configuration.
- Backend-specific support state and its user-facing reason.

It does not probe the ambiguous TrollStore URL scheme. It does not read a complete app inventory through undocumented LaunchServices/private APIs. TrollStore remains unsupported by this DreyzeStore build even on an upstream-compatible OS because this app cannot pass its managed local file through the documented URL flow.

An external URL handler's presence is not proof of the handler's identity or of a successful install. DreyzeStore does not use `canOpenURL` to infer TrollStore presence.

Structural validation also does not prove that iOS will accept an IPA's code signature or provisioning profile. The selected, authorized installation backend and OS make that decision. DreyzeStore reports signature/install failures from that backend and does not claim the archive is installable solely because its metadata parsed.

## Download and validation boundary

1. Request a published release and expected byte size/SHA-256 from the selected repository.
2. Download with a cancellable background-compatible `URLSessionDownloadTask` to a UUID-named app-managed temporary file. The OS owns background scheduling; a manual retry starts a fresh transfer.
3. Check available storage, the 1 GiB hard ceiling, and exact actual byte count. Calculate SHA-256 and compare it to the published value. On mismatch, delete the temporary file and stop.
4. Preflight the ZIP end record and bound central-directory size before opening it, then read the directory and the single `Payload/<AppName>.app/Info.plist`; no archive path is extracted. Validate bundle ID, version/build, minimum OS, and executable entry.
5. Reject absolute/traversal paths, paths deeper than 64 segments, duplicate normalized paths, special entries, escaping symlinks, entry counts above 100,000, expanded size above 8 GiB, an individual entry above 2 GiB, a compression ratio above 1,000, and Info.plist above 8 MiB.
6. Create a validation receipt and immutable `VerifiedPackage` only after checksum, archive, and release metadata all agree. Clean up on cancellation, mismatch, failure, or explicit deletion.
7. `VerifiedPackage` is the installation boundary. Before handoff, Phase 5 confirms the receipt belongs to `PackageStorage`, then repeats the checksum and metadata validation. Only that receipt can reach the backend protocol.

ZIPFoundation 0.9.20 is pinned for central-directory reading and selective entry streaming. The app uses its archive APIs without extracting untrusted package paths and applies explicit limits in `PackageValidator`; ZIP64 sentinel records are currently rejected during preflight. The generated tests exercise malformed archives, traversal, absolute paths, escaping symlinks, compression ratios, entry counts, central-directory size, and metadata mismatches.

## Installed apps and updates

An unprivileged iOS client cannot promise an OS-wide installed-app scan. The Library keeps `Downloaded`, `Handed Off`, `Installed`, and `Updates` separate. Only verified files appear in `Downloaded`; a completed system share activity is recorded in `Handed Off` (up to 100 local history records); `Installed` remains empty until a backend can authoritatively report inventory. Handoff history is not used as installed-app or update input.

`GET /api/v1/updates` provides latest releases; it is not proof of local installation. Updates and uninstall remain unavailable while no production backend provides installed-app inventory and authoritative operation results. No success message is shown just because an external activity ran.

## License and upstream research

Research used the current upstream [TrollStore README](https://github.com/opa334/TrollStore/blob/main/README.md), [TrollStore Lite Makefile](https://github.com/opa334/TrollStore/blob/main/TrollStoreLite/Makefile), [upstream root helper](https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m), [installation controller](https://github.com/opa334/TrollStore/blob/main/TrollStore/TSInstallationController.m), and [upstream license](https://github.com/opa334/TrollStore/blob/main/LICENSE), reviewed on 2026-09-27. The README says supported versions are 14.0 beta 2–16.6.1, 16.7 RC build 20H18, and 17.0; it says 16.7.x other than that RC and 17.0.1+ are not supported. It documents `apple-magnifier://install?url=<URL_to_IPA>` and warns that without TrollStore the scheme opens Magnifier. Its installation controller handles file paths inside its own app and a separate remote-download path; DreyzeStore's verified IPA is in its private sandbox, so it cannot be passed by merely supplying a path. DreyzeStore neither copies upstream code nor probes the ambiguous scheme. TrollStore Lite's target uses private frameworks and a separately built privileged helper; this client does not include it.

The upstream project is MIT-licensed overall and marks `RootHelper/uicache.m` BSD-4-Clause. DreyzeStore only documents the interface and does not redistribute any upstream implementation, so no upstream notices or source are embedded in the app. If a later phase copies or links upstream code, review that exact file's notice and license first.
