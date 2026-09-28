# Troubleshooting

## Catalog and images

- **Couldn’t Load Store**: use pull-to-refresh. If a saved catalog exists, DreyzeStore labels it offline and displays the last cached content.
- **API configuration unavailable**: this RC has no production URL. Build with an operator-provided HTTPS `DREYZE_API_BASE_URL`; Release builds reject HTTP and loopback.
- **No screenshots or icon**: the UI shows a neutral placeholder when an asset URL is absent or the server cannot load the image.

## Download and package verification

- **Download Failed**: check network connectivity, HTTPS reachability, and free device storage, then retry.
- **Package Verification Failed**: DreyzeStore removes the rejected transfer. Do not try to bypass SHA-256 or IPA validation; report the app ID/version and request ID to the repository operator.
- **Package metadata mismatch**: published bundle ID, version, build, minimum iOS, size, or checksum differs from the downloaded IPA. The release owner must correct the publication.
- **Downloaded app disappeared after restart**: saved packages are re-hashed and re-inspected before reuse. A modified or unreadable package is removed from managed storage.

## Companion and device

- **Computer Offline**: start DreyzeStore Companion and keep both devices on the same trusted private network.
- **iPhone Not Connected**: use a data-capable USB cable, unlock the device, accept **Trust This Computer**, then run Companion diagnostics again.
- **Apple Mobile Device Service fails**: install the classic iTunes package that supplies the service; do not use Microsoft Store iTunes for this documented setup.
- **pymobiledevice3 fails**: install it for the Windows user running Companion and restart the app. Do not download binaries from unofficial mirrors.
- **Developer Mode unknown/off**: check iPhone **Settings → Privacy & Security → Developer Mode**. Enable only on a device you own/control and follow iOS restart prompts.
- **Signing Setup Required**: import your own Apple Development identity and a profile that authorizes the connected device, app identifier, and certificate.
- **Profile expired**: obtain a new profile through your own supported Apple signing workflow and replace the local profile. The app uses the profile's actual expiry timestamp.
- **Installation could not be confirmed**: the Companion must read the exact installed bundle ID/version/build back from the iPhone. Reconnect and refresh inventory before retrying.
- **Pairing certificate changed**: do not ignore the change. Forget the old pair only after confirming you are talking to the intended PC, then pair again by scanning its current one-time code.

## Windows installer

The RC installer is unsigned. Windows SmartScreen may show an unknown-publisher prompt. Verify the downloaded artifact against its adjacent `SHA256SUMS.txt`; do not treat a matching hash as proof that the executable is safe. Obtain artifacts only from the project's Actions run/release page.

## Diagnostics

Exported diagnostics must be reviewed before sharing. Never share Apple Account credentials, 2FA codes, pairing tokens/QR payloads, private-key bytes, P12 passwords, full UDIDs, or provisioning profile contents.
