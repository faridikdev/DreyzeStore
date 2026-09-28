# Changelog

## 0.9.0 RC1 — 2026-09-28

This release candidate focuses on first-run guidance, predictable recovery, and physical-device readiness. It is unsigned and requires a configured HTTPS catalog API and the user's own Apple Development signing materials before a real install.

### Catalog

- Native Today, Apps, Search, Updates, and Library screens use the configured catalog API.
- First-run onboarding explains discovery, integrity checks, and the Windows Companion requirement.
- Catalog GET actions open app details instead of displaying an obsolete “installation unavailable” message.
- App details now collapse technical package metadata under **Package Information** and explain what a checksum does and does not establish.

### Downloads and verification

- Existing managed packages are re-hashed and re-inspected before they are restored into a ready-to-install state after app restart.
- Only bytes that still match the stored release SHA-256 and IPA metadata restore the `VerifiedPackage` boundary.
- Download and installation outcomes remain distinct; no install success is inferred from a download or handoff.

### Windows Companion

- Setup, signing, diagnostics, local USB install, and inventory confirmation are documented for the first physical test.
- Test IPA is built from the repository's own small SwiftUI sample source in CI; no IPA is committed.
- NSIS and MSI artifacts are unsigned and carry RC version metadata.

### Updates and refresh

- Update and signing refresh flows continue to require fresh Companion inventory confirmation.
- Offline inventory is labelled with its last checked time and is not presented as a fresh result.

### Admin

- The authenticated release pipeline and publication gates from Phase 6 remain unchanged.

### Known limitations

- Physical iPhone signing/install/update/refresh/uninstall is **NOT VERIFIED** in CI.
- CI does not hold Apple signing credentials. iOS output is unsigned and cannot be installed until signed locally with the tester's own identity/profile.
- Release builds need an operator-supplied HTTPS API base URL. No production API URL, Cloudflare resource, DNS entry, or production secret is configured by this release.
- Standard iOS installation requires the user's own device-matched development signing material on Windows Companion; Apple Account provisioning is not automated.
- App Store privacy/safety certification and malware scanning are outside the package integrity checks.
