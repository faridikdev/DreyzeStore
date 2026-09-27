# Physical-device TrollStore import/install test

**Status:** Plan only. No physical iPhone test has been run. The current repository does not publish an authorized sample IPA, and the admin upload pipeline is not implemented, so this test requires a non-production test catalog and an owner-authorized package before it can run end to end.

## 1. Prerequisites

- A physical iPhone or iPad running an OS/build explicitly listed by the current upstream [TrollStore compatibility notes](https://github.com/opa334/TrollStore/blob/main/README.md), with TrollStore already installed through its supported upstream installation guide. For the Lite case, use a device with a supported jailbreak and TrollStore Lite already installed. Do not attempt this flow on an unsupported version.
- The installed TrollStore/TrollStore Lite import confirmation prompt is enabled in that app's settings. Upstream allows the prompt to be disabled; if disabled, the receiver may proceed without its own second prompt.
- A Mac with Xcode and a development signing identity in the local Keychain to run the DreyzeStore Debug build on the registered test device. Do not export or share its private key, `.p12`, or provisioning profile. Apple lists the App ID, certificate/private key, registered device, provisioning profile, and Developer Mode requirements in its [registered-device guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).
- A small IPA built from source owned by the tester or explicitly licensed for this test. Use a unique bundle ID such as `org.dreyzestore.installtest`, a visible test-only app name, and versions `1.0.0` / `1.1.0`. Do not use a commercial, decrypted, or otherwise unauthorized IPA.
- A non-production API catalog entry with the package's real bundle ID/version/build/minimum OS, exact byte size and SHA-256, and an HTTPS download URL that the iPhone can reach. The current dev seed uses `.invalid` object URLs and fictional hashes; it cannot serve as this test package. Do not use production D1/R2 or change any production secrets.
- For a local HTTPS asset host, install and fully trust its test CA certificate on the test device, verify the TLS hostname, keep it on a private test network, then remove the test CA after testing. Do not weaken DreyzeStore's HTTPS policy or add a general ATS exception.

## 2. Supported environment

Record device model, iOS version and build, jailbreak/TrollStore type and version, DreyzeStore commit, and whether the receiver is TrollStore or TrollStore Lite. The current upstream README lists TrollStore support as iOS 14.0 beta 2 through 16.6.1, the specific 16.7 RC build 20H18, and iOS 17.0; verify this list again immediately before testing because upstream may change it. TrollStore Lite is a separate jailbreak-only build and environment.

## 3. Build and install DreyzeStore

1. On the Mac, check out the exact commit under test and open `ios/DreyzeStore/DreyzeStore.xcodeproj`.
2. Select the `DreyzeStore` scheme, a connected physical iPhone destination, and the tester's own development team. Let Xcode sign the DreyzeStore development app locally; do not add signing material to the repository or CI.
3. Set the Debug `DREYZE_API_BASE_URL` to the non-production test Worker reachable by the phone. Keep the package asset URL HTTPS even if the local API itself is on the trusted test LAN.
4. Build and Run from Xcode. Confirm the app opens and the catalog displays the test release from the configured API.

## 4. Prepare and download the authorized sample IPA

1. Build the sample app from the tester-owned source with a unique bundle ID. Export two test-device-compatible IPAs, first `1.0.0` then `1.1.0`; keep the `1.1.0` package aside until the update test.
2. Place the first IPA in the non-production HTTPS test asset host. Add a local catalog release with matching bundle ID, app version, build, minimum iOS, exact byte count, and SHA-256. Confirm `GET /api/v1/apps/:id` returns the exact test URL and metadata. Do not publish this package in a public catalog.
3. In DreyzeStore, open the test app's details, tap **GET**, confirm the release details, then tap **Download**.
4. Wait for download, checksum verification, and IPA inspection. In **Library → Downloaded**, confirm the package is listed as Verified. If any field or checksum differs, stop; do not open the document menu.

## 5. Handoff and installation confirmation

1. Open the verified package, choose **Install**, then **TrollStore / Lite Import (Open In)**.
2. In Apple's Open In menu, select the expected receiver. Record the receiving bundle ID shown in the DreyzeStore handoff receipt. If neither TrollStore nor TrollStore Lite appears, stop and record the OS build and document-handler state; do not treat another app as TrollStore.
3. Confirm that TrollStore/TrollStore Lite opens and independently displays the package's app identity/version plus its own **Install** and **Cancel** actions.
4. Select **Install** inside the receiving TrollStore app. Wait for its own success or error result. DreyzeStore should show **Handed Off**, never **Installed**. Record both displays separately.

## 6. Verify the actual app

1. Confirm the sample app appears on the Home Screen or in the receiving TrollStore app's own app list.
2. Launch it and verify it displays the test bundle ID/version (or another build marker controlled by the test source).
3. In DreyzeStore, verify the package remains under **Downloaded** and the history says **Handed Off**. DreyzeStore's Library must not claim installed inventory.

## 7. Update flow

1. Publish the owner-built `1.1.0` test artifact only to the same non-production test host/catalog. Keep the bundle ID identical and use a genuinely higher version/build. Recalculate byte count and SHA-256 from the exact hosted file.
2. Refresh DreyzeStore and confirm the release metadata shows `1.1.0`. Download and verify it independently.
3. Hand it to the same TrollStore receiver and confirm the version/update details in TrollStore before selecting its install/update action.
4. Launch the sample app and verify its own build marker is now `1.1.0`. DreyzeStore should again say **Handed Off**; this project has no installed-app inventory or update confirmation source yet.

## 8. Cleanup and evidence

- Save non-sensitive evidence: device/OS build, DreyzeStore commit, receiving app bundle ID, package SHA-256, TrollStore's own result, launched app version, and DreyzeStore's `Handed Off` state. Redact serial numbers, UDIDs, Apple account details, and local network secrets.
- Use DreyzeStore to delete only the two test packages it downloaded, and remove only the test IPA/catalog row from the non-production test host/database. Remove the temporary trusted test CA if one was installed.
- Do not erase/reset the device, change jailbreak state, remove TrollStore, delete other apps/data, uninstall the test app as part of this procedure, or touch production services. Leave the test app installed unless its owner separately chooses to remove that exact bundle from TrollStore's own app manager.

## 9. Result criteria

Mark the physical import/install path **VERIFIED** only when TrollStore/TrollStore Lite itself displays and completes the install, the uniquely identified test app launches at the expected version, and DreyzeStore reports only **Handed Off**. A simulator test, unit test, Open In menu appearance, or completed file-send callback alone is not a physical installation verification.

Record one of:

- `VERIFIED` — all criteria above passed on a physical supported device.
- `FAILED` — a supported device reached the flow but a documented step failed; include OS/build and redacted logs.
- `NOT TESTED` — no supported device or owner-authorized sample release was available.
