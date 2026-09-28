# Changelog

## PHASE 8.5 — Windows Apple Account provisioning prototype (2026-09-28)

- Added an opt-in local Apple Account login/2FA, development-team selection, explicit USB device registration, and certificate preparation flow using pinned upstream `isideload`.
- Added user-selected HTTPS Anisette V3 endpoint with a trust acknowledgement; the Companion explains the ADI/Anisette data sent to that operator.
- Added local session/private-key storage through Windows Credential Manager and stable team-suffixed bundle IDs. Signing still passes through the existing package validation/install/inventory-confirmation boundary.
- Added a fail-closed package compatibility gate and validation of the returned team, app ID, device, certificate/profile dates before installation.
- Live Apple Account provisioning and physical iPhone installation remain **NOT TESTED / NOT VERIFIED**. This is an experimental reverse-engineered workflow, not an Apple-supported Windows API.
- The transitive `apple-codesign-quick` dependency is LGPL-2.1-or-later; shipping a linked Windows binary requires a relinking/source compliance review.

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
- Windows Apple Account provisioning is experimental and unverified; imported user-owned signing files remain an alternative.
- App Store privacy/safety certification and malware scanning are outside the package integrity checks.
