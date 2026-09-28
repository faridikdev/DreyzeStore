# Apple authentication security

## Data flow

Apple Account authentication and provisioning run on the user's Windows PC through the pinned upstream `isideload` crate. Password and 2FA input are not sent through the DreyzeStore catalog/backend/admin. The user-selected anisette provider is a separate outbound service and receives Anisette protocol data, not the Apple credentials as passed by DreyzeStore.

| Data | Handling |
|---|---|
| Apple email | Sent to Apple by the upstream auth flow; stored locally in Windows Credential Manager for account display/session restoration; UI displays a masked value |
| Password | Entered in the Companion UI, cleared from UI state after request begins, held in a Rust `Zeroizing<String>` during initial auth, sent to Apple auth flow; not persisted |
| 2FA code | One-use input sent to Apple auth flow; wrapped in a zeroizing value at the Tauri command boundary; not persisted |
| Apple session token and ADSID | Saved in Windows Credential Manager for local session reuse; never sent to DreyzeStore or anisette endpoint |
| Anisette endpoint URL | User-selected HTTPS endpoint, stored locally in Windows Credential Manager |
| ADI/Anisette state | Persisted in Windows Credential Manager by the upstream provider and sent to the selected anisette service as required by the V3 protocol |
| Signing key/certificate identity | Generated/reused locally through the upstream signing storage backed by Windows Credential Manager; not uploaded to DreyzeStore |
| IPA and signed app | Managed local package directories; each package still goes through the existing validation and install coordinator |

## User-facing controls

- The Companion identifies itself as DreyzeStore, not as an Apple app or Apple web page.
- Before login, the user sees that this is an unofficial, reverse-engineered Apple protocol and explicitly confirms trust in the selected anisette operator.
- Team choice and device registration require explicit user action. No automatic certificate revocation is configured.
- Sign out clears local session/account/team/device-registration/expiry records but leaves locally generated signing key material in the local keyring. It does not revoke Apple-issued certificates or remove installed apps.
- Errors are intentionally generic. Detailed upstream request bodies are not surfaced or logged by the application.

## Threat assumptions and residual risks

The selected threat model is one local Windows user. A malicious process or administrator running as that same Windows user may be able to inspect process memory or use credentials available to that user; Credential Manager/DPAPI do not protect against a fully compromised unlocked account. A malicious anisette operator sees its protocol data. TLS protects transport against passive network observers but does not make the operator trustworthy. Apple can change undocumented endpoints at any time.

The upstream signing dependency graph includes `rsa 0.9.10`, which RustSec flags as RUSTSEC-2023-0071 (Marvin timing side channel; no fixed release is available). DreyzeStore currently uses it only for local CSR and code-signature generation, not as a network-facing RSA decryption oracle. The root `.cargo/audit.toml` contains a visible, time-bounded audit exception based on RustSec's local-use workaround. This remains a known residual risk and must be re-reviewed before each Companion release.

The feature is experimental and has not been exercised with real Apple credentials or a physical iPhone in this phase. Never paste credentials into diagnostics, issues, screenshots, or chat. Report failures only after redacting account identifiers, codes, tokens, UDIDs, and provider-specific metadata.
