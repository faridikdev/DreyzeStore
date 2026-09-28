# Anisette provider

## Current implementation

The pinned `isideload` 0.4.0 integration implements Remote Anisette V3. There is no local Anisette provider in this Companion build. The UI pre-fills the upstream library's default HTTPS endpoint, but the user must explicitly confirm trust; the endpoint is editable and the UI requires HTTPS without embedded credentials, query strings, or fragments.

The selected operator receives Anisette protocol material, including a generated keychain identifier and ADI provisioning state (`adi_pb`) used by the upstream protocol. The operator is **not sent** the Apple email, password, 2FA code, or reusable Apple developer session by DreyzeStore. The provider can observe the protocol requests and responses it handles, so it is still a meaningful third-party trust boundary. Use a service you trust or a service you operate. Do not assume the operator's privacy/security properties from HTTPS alone.

The anisette value is stored locally in Windows Credential Manager to keep the same provider for session restoration. Network requests use the upstream HTTPS/WSS implementation. DreyzeStore does not log protocol bodies or call the upstream verbose initialization hook; errors surfaced to the UI are deliberately generic.

## Boundaries

- No Apple Account password, verification code, session token, or email is sent to the anisette endpoint by the DreyzeStore integration.
- Anisette protocol values remain sensitive device/authentication metadata. Their confidentiality from a chosen provider cannot be guaranteed; choosing that provider is an explicit user decision.
- The HTTPS check rejects plain HTTP and URLs with user-info, query, or fragment. The selected host is not treated as trustworthy merely because TLS succeeds.
- A local provider remains a future option. The pinned upstream library exposes the remote V3 provider used here; a local implementation would require a separate license, protocol, and platform review.
- The catalog API is not involved in Apple authentication or provisioning.

See [Apple authentication security](apple-auth-security.md) and the repository [threat model](../DreyzeStore-threat-model.md).
