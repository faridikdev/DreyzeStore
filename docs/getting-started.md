# Getting started

This guide is for a local developer checkout and the unsigned `0.9.0 RC1` artifacts. The RC does not include a deployed catalog API. Do not use the `.invalid` seed URLs as package downloads.

## Developer requirements

- Node.js 22.12 or newer and npm.
- Python 3 for the repository validator and migration checks.
- macOS with Xcode to build the iOS client or the device-test sample.
- Windows 11, Rust MSVC, Visual Studio C++ Build Tools, Python, classic iTunes Apple Mobile Device Service, and `pymobiledevice3` for the Companion/device path.

## Local catalog

```sh
npm ci
npm run db:migrate:local
npm run db:seed:local
npm run dev:api
```

The fictional seed metadata intentionally points at reserved `.invalid` hosts. It supports browsing and API development, not real downloads. Run the admin locally in another terminal with `npm run dev:admin` after following [admin setup](admin.md).

For an iPhone, build an HTTPS development endpoint reachable by the phone and configure `DREYZE_API_BASE_URL` for the Release configuration. Release does not allow plain HTTP or loopback. A public/trusted HTTPS endpoint is required; this guide does not create a tunnel, domain, Cloudflare resource, or production deployment.

## First physical Companion test

1. Download the latest `DreyzeStoreCompanion-windows-x64` CI artifact from the repository's Actions page. Read `SHA256SUMS.txt`, then compare the selected installer locally with `Get-FileHash .\<installer-file-from-artifact> -Algorithm SHA256` in PowerShell. Only run the installer if the digest matches the corresponding manifest entry. The MSI-compatible numeric prerelease version is `0.9.0-1`; the Companion presents it as `0.9.0 RC1`.
2. Install the documented Windows device dependencies and connect an unlocked iPhone over USB.
3. Trust the Windows PC on the phone and enable Developer Mode manually if the device requires it.
4. In Companion, run diagnostics and import your own Apple Development `.p12` and device-matched `.mobileprovision`.
5. Pair DreyzeStore with the Companion over its one-time QR code and verify that the pinned local connection is live.
6. Use the CI-generated `DreyzeDeviceTest-sample.ipa` from the same run for the first non-destructive install test. The package is built from [the sample source](../ios/DeviceTestSample) and is not committed.
7. Read [the physical-device test plan](physical-device-install-test.md) before attempting install, update, refresh, or uninstall.

The current CI artifact is not signed with an Apple identity. Companion now includes an experimental Windows Apple Account provisioning flow, but Apple's acceptance and physical installation have not been tested; it is not an Apple-supported Windows workflow. You can also import signing material you own and a matching profile. See [Apple signing and provisioning limits](apple-signing.md) before entering credentials.

## iOS build

On macOS, open `ios/DreyzeStore/DreyzeStore.xcodeproj`, choose an available simulator, and build/test with the documented CI command in [README](../README.md). CI produces an unsigned device build artifact. It contains no signing certificate/profile and is not an installable IPA.

## Support

Use [troubleshooting](troubleshooting.md) and [release test matrix](release-test-matrix.md). Keep pairing QR codes, UDIDs, Apple credentials, P12 files/passwords, provisioning profiles, and package contents out of issues and logs.
