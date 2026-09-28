# Release test matrix — 0.9.0 RC1

Status values: **Automated** means an existing test/CI job covers the check; **Manual** means an operator must perform it; **Blocked** means required infrastructure/device credentials are intentionally unavailable. No result below should be inferred from an artifact being built.

| Area | Check | Type | Result / evidence |
|---|---|---:|---|
| Install | Fresh install and first launch | Manual | Run on simulator and a clean test iPhone; onboarding is one-time and dismissible only through its explicit CTA. |
| Install | iOS launch without network | Manual | Cached catalog is labelled offline; empty cache shows retry. |
| Catalog | Today, categories, pagination and repository metadata | Automated + Manual | Backend/shared tests plus device layout check. |
| Search | Debounce, cancellation, recent history, empty state | Automated + Manual | Search model tests and keyboard/VoiceOver check. |
| Download | HTTPS release download and actual progress | Automated + Manual | Local test-server pipeline tests and device network run. |
| Verification | Wrong SHA, invalid ZIP, missing Payload, malformed metadata | Automated | iOS package validator XCTest and Windows validator tests. |
| Companion | Pairing, certificate pin, Companion offline, USB disconnect | Automated + Manual | Companion auth tests; physical test must cover reconnect. |
| Signing | Missing/expired identity and profile | Automated + Manual | Signer tests; physical device profile required for final behavior. |
| Install | Package is signed, installed and inventory-confirmed | Automated mock + Manual physical | Mock is not device verification. Physical iPhone status: **NOT VERIFIED**. |
| Update | Old version → latest release → verified package → confirmed inventory | Automated mock + Manual physical | Phase 7 local E2E is mock-backed; repeat on device. |
| Refresh | Actual profile expiration and same-version resign | Automated mock + Manual physical | Never alter the PC clock to fake expiry. |
| Uninstall | Removal followed by inventory absence | Automated mock + Manual physical | Must retain downloaded IPA unless user separately deletes it. |
| Recovery | Restart during download/update and stale temp cleanup | Automated + Manual | Reopen app and confirm only verified stored packages remain ready. |
| Storage | Clear cache, old packages, all downloads | Manual | Confirm installed apps remain installed. |
| Visual | Small/standard/large iPhone, light/dark, long text | Manual | Simulator screenshot/VoiceOver inspection is required for each RC. |
| Accessibility | VoiceOver, Dynamic Type, Reduce Motion, touch targets | Manual | Use simulator accessibility inspector and device VoiceOver. |
| Admin | Validation errors, upload progress, publish confirmation, narrow layout | Automated + Manual | Admin tests/build plus browser width and unsaved changes check. |
| Windows | NSIS/MSI install/uninstall and version metadata | CI + Manual | Unsigned artifacts; hash manifest required. |
| Release | Secret/artifact scan and dependency review | Automated + Manual | Run the release checklist against exact tag/artifact. |

## RC acceptance blockers

- Physical iPhone install/update/refresh/uninstall must be run by a tester using their own device and signing files.
- The RC catalog client requires an operator-supplied HTTPS API URL. No production API has been deployed or configured.
- Unsigned Windows installers require an explicit user decision to run; verify artifact checksums and provenance first.
