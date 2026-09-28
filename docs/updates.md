# Updates and installed inventory

Phase 7 uses the paired Windows Companion's current device inventory as the only source of truth for installed versions. A downloaded IPA, a prior handoff, or a published catalog release never marks an app as installed.

## Inventory

The iOS client calls the paired Companion's authenticated `GET /api/v1/apps?udid=…` endpoint when Updates or Library is opened, when the user pulls to refresh, and after update, refresh, or uninstall. The Companion queries the selected iPhone and returns each device-reported bundle ID, version, and build. It labels a record `companionConfirmed` only when the app's signed bundle ID, version, build, and paired device match a DreyzeStore installation record. Other device results are `localRecordOnly` or `unknown`; the client does not show those as DreyzeStore-installed.

The Companion hashes the device UDID before returning `deviceIdentifier`. The full UDID remains on the paired Windows PC. The client caches snapshots for up to 30 days, scoped to the paired device hash. A cached snapshot is labelled with its last check time, is not considered live, and cannot authorize update, refresh, or uninstall operations.

Canonical app identity is `originalBundleIdentifier ?? installedBundleIdentifier`. Update requests use this canonical catalog identity while inventory confirmation also checks the exact signed bundle ID returned by the Companion. This supports future deterministic bundle-ID rewriting without treating another app as the catalog app.

## Update check API

The iOS client posts batches of at most 25 confirmed inventory records to `POST /api/v1/updates`:

```json
{
  "apps": [
    {
      "bundleIdentifier": "com.dreyze.sample",
      "version": "1.9",
      "build": "2026.9",
      "channel": "stable"
    }
  ]
}
```

The response includes only published releases newer by semantic version, or by natural build ordering when the version is equal. Stable requests never receive beta-only releases. Beta requests can receive stable or beta releases. The update response is `Cache-Control: no-store` because it is specific to installed inventory.

The client uses `POST /api/v1/apps/lookup` with a bounded batch to resolve apps that have a current published release but no update. That endpoint returns only public apps/releases and does not disclose drafts or staging metadata. These two endpoints are documented with response examples in [the API reference](api.md).

## Update pipeline and confirmation

```text
live Companion inventory
  → published release lookup for the selected channel
  → local compatibility/version/build check
  → existing DownloadManager
  → declared size + SHA-256 + IPA structure/metadata validation
  → VerifiedPackage
  → paired Windows Companion revalidation/sign/install
  → fresh live inventory read
  → exact canonical ID + signed ID + version + build confirmation
  → local history entry and optional old-package cleanup
```

Updates use the normal Phase 4 `DownloadManager`; there is no separate update downloader or checksum bypass. The existing Companion verifies the transferred package again, signs locally, installs it, and queries the device inventory. The iOS client then fetches inventory again and shows `Updated` only if the expected bundle identities, version, build, device hash, and `companionConfirmed` source match. An installation receipt alone is insufficient.

If verification, signing, install, or final inventory confirmation fails, the previous device version remains the current reported version, no successful history record is created, and the new package remains available only if the normal download pipeline completed verification. Existing verified package cleanup runs only after confirmation and only when **Keep Previous Version** is turned off. This preference is on by default to preserve a local copy; no automatic app rollback is performed.

Update All runs installations serially so one iPhone and signing identity are not driven concurrently. A failed item does not stop later items. Each item retains an independent state and can be retried. Downloads are therefore also serialized in the current Update All flow (one at a time, below the requested 2–3 maximum).

## States and compatibility

`UpdateState` models `upToDate`, `updateAvailable`, `downloading`, `verifying`, `readyToInstall`, `connectingToCompanion`, `signing`, `installing`, `confirming`, `updated`, `failed`, `incompatible`, `signingExpired`, and `companionUnavailable` without overlapping boolean flags. A release requiring a newer iOS version is shown as incompatible and cannot be started. A published release older than the live installed version/build is ignored; automatic downgrades are never offered.

## Update channels

The default channel is **stable**. Beta is an explicit user preference under Settings → Updates. Stable checks filter to stable releases on the server. Beta checks may select beta or stable releases according to semantic version/build precedence. The selected channel is included in cache keys and requests, so stable cached results cannot be reused as beta results.

## Update history and notifications

The client keeps at most 200 local update/refresh history entries without credentials or package bytes. Local notifications are opt-in from Settings and scheduled only after a live inventory and successful online update check. Notifications identify changed update fingerprints and provisioning expirations. Notification delivery is controlled by iOS; the app does not run an hourly timer.

## Offline behavior

Last successful update results are cached for at most seven days and scoped by device hash, current installed version/build set, and channel. Cached results can be read while offline but never enable an install. Companion inventory can still be read over the local network while the public API is offline; the UI reports those two availability states separately.

The app does not promise a fixed background update schedule. No `BGAppRefreshTask` is registered in this phase. Users can open Updates or pull to refresh for a live check.

## Testing boundary

Runtime-generated, project-owned ZIP/IPA fixtures are used by tests and are not committed. iOS tests exercise the real `DownloadManager`, checksum validation, and `PackageValidator` with an injected local test transport plus a test-only Companion/device inventory. Rust Companion tests exercise its validator, test signer, mock device install, and exact inventory confirmation. These mock-device tests do not establish physical iPhone installation; see [the physical test plan](physical-device-install-test.md).
