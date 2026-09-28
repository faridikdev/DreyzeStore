# Signing refresh

Signing refresh renews the installed app's local development signature using the original DreyzeStore-managed package retained by Windows Companion. It does not fetch a newer app release and does not change the app version or build.

This flow still requires a live Companion inventory and the actual profile expiry; stale snapshots cannot start refresh. RC documentation does not treat simulated expiry or mock-device tests as physical validation.

## Eligibility

Refresh is available only for an app marked `companionConfirmed` in a fresh inventory from the currently paired iPhone and when Windows Companion is connected with a valid local signing setup. `localRecordOnly`, `unknown`, and stale cached inventory never authorize refresh.

The Updates screen's **Expiring Soon** section is driven by each inventory record's actual `provisionExpiration`. The default warning window is seven days and can be configured from one to 30 days in Settings → Updates. An already expired profile remains visible for recovery. The app does not assume all provisioning profiles have the same lifetime.

## Flow

1. DreyzeStore sends the canonical bundle identity to authenticated Windows Companion `POST /api/v1/refresh`.
2. Companion checks that its managed original package belongs to the selected device, revalidates its hash and IPA metadata, and checks current certificate/profile/device compatibility.
3. Companion signs and reinstalls the same release using the configured local identity.
4. Companion reads the iPhone app inventory and returns success only for the exact bundle ID, version, and build.
5. DreyzeStore fetches a fresh inventory and requires a matching `companionConfirmed` record with a valid, renewed expiration before adding a `refreshed` history entry.

An expired signing setup may need to be replaced on the user's Windows PC before refresh can proceed. Apple signing materials and credentials remain local; refresh never calls the DreyzeStore cloud backend with signing data.

## Refresh All

Refresh All processes each eligible app sequentially and reports per-app success/failure. It does not launch multiple signing/install operations at once. A failure does not cancel the remaining apps. No refresh operation is considered complete from a Companion command result alone; it requires fresh device inventory and a later provisioning expiration.

## Background behavior

The iOS app schedules only opt-in, best-effort local notifications for the actual profile expiration date minus the selected warning interval. It cannot refresh apps while Windows Companion is unavailable, and no fixed background task schedule is promised. Companion may run its own local checks while it is open, but this version does not perform silent background signing or installation.
