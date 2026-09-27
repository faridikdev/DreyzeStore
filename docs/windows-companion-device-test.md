# Windows Companion Physical iPhone Test Plan

**Status: NOT TESTED on a physical iPhone.** Run this only with an iPhone, Apple Development identity, and app package that you own or are authorized to distribute. The generated ZIP fixtures used by CI are metadata test fixtures, not launchable iOS applications.

## Prerequisites

- Windows 11 x64 with the unsigned development MSI/NSIS artifact installed.
- Classic iTunes for Windows installed from Apple so Apple Mobile Device Service is present.
- Python 3 with `python -m pip install -U pymobiledevice3`.
- A test iPhone with a data-capable USB cable, unlocked and owned by the tester.
- An iOS 26-compatible Apple Development certificate and matching provisioning profile which includes this device UDID and the test app's bundle ID. Create them with an Apple-supported workflow; do not use shared/leaked certificates.
- Developer Mode enabled manually on iPhone: Settings → Privacy & Security → Developer Mode → restart → confirm Enable.
- A launchable IPA for an app the tester owns or has distribution permission for. Do not use pirated packages or put the IPA in Git.
- Both devices on the same private Wi-Fi/LAN with local client isolation disabled for this pair. Keep Windows Firewall enabled.

## Test procedure

1. Install the unsigned DreyzeStore Companion MSI. Start it and confirm the local API reports ready.
2. Install the documented Windows device service dependency, restart Companion, connect the iPhone by USB, unlock it, and tap **Trust This Computer** on the iPhone. Verify the displayed device name, iOS version, and masked UDID.
3. Verify the Developer Mode indicator reads **Enabled** when supported by the device service, or **Unknown** otherwise. If unknown, check Settings on iPhone manually. Do not treat unknown as proof that it is enabled.
4. Import a locally created Apple Development P12 and the device-matched provisioning profile. Enter the P12 password only into Companion. Verify the UI reports the profile expiration and never prints the password.
5. In DreyzeStore iPhone app, open Settings → Installation → Connect Windows Companion. Scan the current Companion QR. Confirm the endpoint is private HTTPS and the shown fingerprint matches; complete the short-lived pair prompt.
6. Use an authorized, published test release whose public API digest matches the IPA. Open App Details → GET, complete the iPhone download, checksum verification, and IPA structure/metadata validation.
7. Review the package confirmation (version, bundle ID, size, source, Windows Companion) and tap Install. Observe transfer → companion verification → provisioning validation → signing → device install.
8. Wait for Companion's inventory readback. Confirm DreyzeStore reports **Installed** only for the exact expected bundle ID/version/build. If install ends with an error or timeout, check the technical details and do not manually mark it installed.
9. Launch the installed test app from the iPhone Home Screen. Confirm expected basic behavior and preserve user data.
10. Restart the iPhone normally, then launch the app again. Record whether the development signature remains accepted and any on-device trust prompt.
11. Invoke uninstall through the paired Companion only for this test app. Confirm it disappears from device inventory before treating the operation as complete.
12. Remove the local signing identity and pairing token if the machine/device will no longer be used for testing. Delete the local test release/package according to its distribution terms.

## Record for a verified report

Record exact Windows version, Companion build hash, `pymobiledevice3` version, iOS version/build, profile expiration, package bundle/version/build/SHA-256, observed stage transitions, inventory result, whether app launch survived restart, uninstall inventory result, and sanitized logs. Never include Apple credentials, private keys, full UDID, pairing token, or IPA bytes in the report.
