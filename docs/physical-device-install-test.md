# Physical iPhone installation test

**Status: NOT VERIFIED.** No physical iPhone or real Apple Account was available for this development run. Unit tests, CI IPA generation, and mocked device tests do not prove Apple provisioning or installation on hardware.

This procedure uses the Windows Companion's real local test-install action. It only accepts a test app with a bundle ID beginning `org.dreyzestore.test.`. Use a package you wrote or have permission to install. Do not use a commercial, decrypted, or otherwise unauthorized IPA.

## 1. Requirements

- A Windows 11 x64 PC with the DreyzeStore Windows Companion installed.
- Apple's classic Windows iTunes package, which provides Apple Mobile Device Service, and `pymobiledevice3` installed as described in [Windows Companion](windows-companion.md).
- A physical iPhone, USB data cable, device passcode, and an Apple Account whose team may register this iPhone and provision a development app.
- Developer Mode enabled manually on iPhone under **Settings → Privacy & Security → Developer Mode**, followed by the restart and confirmation prompts.
- A trusted anisette endpoint selected by the user. The current implementation is an unofficial reverse-engineered Apple protocol and may fail even with a valid Apple Account. Manual `.p12`/`.mobileprovision` import remains the fallback path.
- The `DreyzeStore-RC-device-test.ipa` from a successful public CI run for the commit being tested, or an IPA built locally from source with bundle ID `org.dreyzestore.test.store`.

Apple documents that a free Personal Team is managed in Xcode; development profiles expire 7 days after issuance and require rebuilding/reinstalling after expiry. Personal Teams also have limits on registered App IDs, devices, and installed apps. See [Apple's current account overview](https://developer.apple.com/help/account/basics/about-your-developer-account). Use the actual profile/certificate expiry dates shown by the Companion; do not infer signing status from a fixed duration.

## 2. Configure local signing on Windows

1. Open Companion → **Apple Signing**. Read the notice that Apple does not support this reverse-engineered Windows provisioning flow.
2. Enter the Apple Account credentials in the Companion form. Choose an Anisette HTTPS endpoint and explicitly confirm that you trust its operator. The endpoint receives Anisette/ADI protocol data; DreyzeStore does not send it the Apple email, password, 2FA code, or reusable session.
3. If Apple requests a verification code or trusted-device approval, complete it in the Companion flow. The one-time code is not saved.
4. Select a team. If Apple returns one team it is selected automatically. With multiple teams, choose the team that owns the Apple Account and understand which team will register the device.
5. Connect/unlock the iPhone, accept **Trust This Computer** on the phone, and confirm **Register iPhone**. Registration is an Apple account action and may consume a team device slot.
6. Choose **Prepare signing**. The Companion reuses or creates a local development identity without automatically revoking another certificate. A successful button result means the local signer found/prepared an identity; it does not prove a package will be accepted on the device.

No Mac or manually prepared `.p12`/profile is intended for this experimental route. If Apple rejects auth, provisioning, signing, or install, stop and capture only redacted diagnostics. You can instead import your own matching `.p12` and profile through the advanced fallback section. Never send account credentials, 2FA, signing files, tokens, or full UDID to DreyzeStore backend or support.

## 3. Download and verify the DreyzeStore RC test package

1. Open [the repository's GitHub Actions page](https://github.com/faridikdev/DreyzeStore/actions) and select the successful CI run for the commit being tested.
2. Download artifact `DreyzeStore-iOS-0.9.0-rc.1` and verify `DreyzeStore-RC-device-test.ipa` against its adjacent `SHA256SUMS.txt` before extracting or selecting it. This is the DreyzeStore client built from this repository with the deliberately reserved bundle ID `org.dreyzestore.test.store` so the Companion's test-only allowlist remains in force.
3. CI also provides `DreyzeDeviceTest-sample.ipa`, a minimal app compiled dynamically from `ios/DeviceTestSample/`. Use that artifact if you want to validate device service/signing independently from DreyzeStore UI.

If you build from source locally, run `bash scripts/package-dreyzestore-device-test-ipa.sh <DreyzeStore.app> <output.ipa>` after building with `PRODUCT_BUNDLE_IDENTIFIER=org.dreyzestore.test.store`. The script refuses any other bundle identifier. Generated IPAs are not committed.

The CI DreyzeStore artifact contains the checked-in `.invalid` Release API URL. It can exercise launch, onboarding, Companion pairing and device installation, but it cannot load a real catalog. To exercise catalog/download/update flows, build a separate test artifact with an approved reachable HTTPS API URL and a non-production catalog; no such service is deployed by this phase.

## 4. Run readiness and import the identity

1. Install the unsigned Windows Companion from the CI artifact after checking its `SHA256SUMS.txt`. Open it → **Apple Signing** → **Run Diagnostics**.
2. Confirm **Apple Mobile Device Service** and **pymobiledevice3** pass. Connect and unlock the iPhone, tap **Trust This Computer**, and rerun diagnostics. A device not returned by USBMux is shown as **Unknown** because this service cannot distinguish an unplugged phone from one still waiting for Trust.
3. Confirm Developer Mode in iPhone Settings. Diagnostics may report **Unknown** because current device discovery does not expose that field.
4. Choose **Import signing files**, select the `.p12` and matching `.mobileprovision`, and enter the P12 password into the password field. The Companion encrypts the files with DPAPI and stores the password in Windows Credential Manager. It checks the P12 certificate against the profile, displays the certificate/profile expiry and team, and never sends these materials to the store backend.
5. A passing provisioning diagnostic means the profile is current, contains the connected iPhone, and authorizes the imported certificate. The specific test app bundle ID is checked again during installation.

## 5. Install and confirm

1. Open **Test Installation → Choose Test IPA** and select `DreyzeStore-RC-device-test.ipa` or the minimal sample artifact.
2. Review the displayed app name, bundle ID, version/build, and size. Confirm the install.
3. Wait for local IPA validation, profile checks, signing, the USB install command, and the device inventory readback. The UI reports success only after inventory contains the exact bundle ID/version/build.
4. On the iPhone, find and launch **DreyzeStore RC** (or the minimal sample app). Confirm the visible screen. Companion does not claim it launched the app because it does not use a launch API in this test flow.
5. Return to Windows Companion and choose **Uninstall test app**. Confirm removal. The record is cleared only after the iPhone inventory no longer contains the test bundle ID.

If authentication, provisioning, signing, installation, or inventory confirmation fails, save the user-facing error and sanitized technical detail. Do not mark the app installed manually. Do not remove or reset unrelated apps/data. If Apple does not accept the experimental flow, the expected result is **FAILED/NOT VERIFIED**; do not claim the no-Mac path works based only on UI or mock tests.

## 6. Pair DreyzeStore with Companion

1. Launch DreyzeStore RC and complete its first-run introduction. On the final page choose **Connect Windows Companion** or open **Settings → Windows Companion**.
2. In Companion choose **Connect iPhone → Generate QR code**, then scan the one-time code in DreyzeStore. Confirm that the live paired connection and device are shown.
3. Relaunch DreyzeStore and confirm the device/settings status is current. The downloaded CI test package can pair and show UI, but its `.invalid` catalog endpoint blocks browsing/downloading until a separate HTTPS development API is configured.

The normal store download route starts with an API release, then uses iOS `VerifiedPackage` verification before the local Companion revalidates/signs/installs. Repository seed URLs use `.invalid` and cannot provide an installable package. No published sample IPA is checked in or hosted publicly.

## 7. Phase 7 update and refresh check

After a Companion install is confirmed, publish or configure an owner-authorized newer build of the same test app in a private/local development catalog. Open DreyzeStore → Updates and refresh. Confirm the installed old version/build comes from the live Companion inventory, then run **Update** and wait for download, checksum/package inspection, Companion signing/install, and a second live inventory read. DreyzeStore should show **Updated** only when inventory reports the exact new signed bundle ID, version, and build. If Companion disconnects before confirmation, DreyzeStore must not show Updated. The prior app remains reported until a later live inventory confirms replacement.

For signing refresh, use a profile nearing its real expiry and verify the profile expiration changes in the new live inventory while the app version/build stay the same. Do not change the PC clock or edit local installation records to simulate expiry. Refresh All should process apps serially and report each result separately.

## 8. Report the outcome

Record the Windows/Companion build, `pymobiledevice3` version, iPhone model and iOS build, certificate/profile expiry, test app bundle ID/version/build, and whether device inventory confirmed both installation and removal. Keep the full UDID, passwords, pairing token, private key, P12, profile, and IPA out of logs/issues.

Use one result:

- `VERIFIED` — the physical iPhone inventory confirmed the app after install, the app launched with the expected marker, and inventory confirmed its removal.
- `FAILED` — a physical install was attempted and a step failed; include the iOS build and redacted diagnostics.
- `NOT TESTED` — no supported physical iPhone or owner-authorized test package was available.
