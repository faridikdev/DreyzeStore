# Security architecture

**Status:** Security design baseline. Phase 2 applies these controls to the public catalog API (bounded validation, prepared D1 queries, allowlisted DTOs, request IDs, non-wildcard CORS, and safe caching). Admin and package controls below describe future implementation requirements; this document is not a certification that those later integrations are secure.

## Assets and trust boundaries

| Asset | Boundary / owner |
|---|---|
| Admin identity, sessions, roles | Hono API and D1; browser holds only an HttpOnly session cookie and an anti-CSRF token. |
| Admin OAuth client secret, session HMAC key, GitHub dispatch credential, R2 S3 signing credentials | Cloudflare Worker secrets; never in source, generated web assets, IPA, logs, or client config. |
| Pending IPA | Private staging R2 bucket, scoped upload/read capabilities, short lifecycle. |
| Published IPA and artwork | Public immutable R2 bucket/CDN; every release is explicitly rights-confirmed and validated before publication. |
| Catalog metadata and expected digest | D1/API or a third-party HTTPS source; treated as publisher-controlled, untrusted input. |
| Downloaded package | iOS app temporary directory until digest and package checks pass. |
| Validation runner | Ephemeral standard GitHub-hosted runner; parses untrusted archive data and must not execute it. |

Main threats include account takeover, unauthorized publication, malicious or malformed repository data, API/CDN compromise, tampered downloads, archive/path/zip-bomb attacks, leaked presigned URLs, replayed upload reports, XSS in admin/catalog text, resource exhaustion, and accidental distribution of packages without rights.

## Admin authentication and authorization

- Use GitHub OAuth as the first admin identity provider; allowlist immutable provider user IDs in `admin_users`, not mutable usernames alone. Do not store a local admin password. GitHub Actions OIDC is a separate mechanism used only by the validator reporting job.
- Exchange the authorization code on the Worker with PKCE/state validation. Keep the OAuth client secret only in Worker secrets and discard provider access tokens after identity resolution unless a later, documented feature requires them.
- Create a random opaque session token; store only its keyed hash in D1. Cookie flags: `Secure`, `HttpOnly`, `SameSite=Lax`, narrow path, bounded lifetime. Rotate on login/privilege change; revoke on logout, password/security event, or disablement.
- Require exact `Origin` allowlisting and a synchronizer CSRF token for every state-changing request. CORS allows only the configured admin origin and credentials; no wildcard origins.
- Apply role-based authorization on every admin route. Hiding buttons in React is not authorization.
- Rate-limit login initiation/callback and mutation endpoints. Use short-lived D1 counters keyed by an HMAC of the client IP plus route/user, and edge controls when available. Never persist raw bearer credentials in rate-limit or audit rows.
- Audit actor, action, resource, timestamp, request ID, and minimal pseudonymous IP metadata. Never log passwords, OAuth codes/tokens, cookie values, upload lease URLs, or raw IPA bytes.

## Upload and validator isolation

- Admins can upload only to unique private staging keys created by the API. Limits include upload size, part count, per-admin concurrency, expiry, and allowed MIME/extension checks. MIME and `.ipa` extension are hints, not validation.
- Presigned URLs grant only the necessary single-object operation and expire quickly. Treat the complete URL as a bearer token; redact it from logs and UI telemetry. Do not make staging public.
- The validation runner is dispatched from a protected default-branch workflow. Pin third-party GitHub Actions by full commit SHA; grant only required permissions. The archive parser job receives no cloud secrets and no OIDC permission. It never runs binaries, scripts, install hooks, or code from the IPA.
- A separate reporting job obtains an OIDC token only after parsing. The Worker checks GitHub's signature/JWKS, exact audience, issuer, repository, workflow path/ref, and job conditions before issuing a short-lived read lease or accepting a report. It associates the report with one unexpired upload ID and accepts each transition once; retries are idempotent.
- Bound response size and validate every reported string, size, digest, app ID, and version. The worker only trusts metadata after comparing it with its upload record and admin's target app. Publish requires a separate authenticated admin review action.
- Compute SHA-256 from the staged bytes in the validator; never trust a hash from the admin browser. After publication, package keys and bytes are immutable. Record size, digest, bundle ID, version/build, upload time, validator identity/run, publishing actor, and audit event.
- Clean up rejected/expired staging objects and incomplete multipart uploads. Published releases are not silently overwritten; deletion/unpublish is a soft state transition and separately audited.

GitHub documents OIDC tokens as short-lived workflow identity and requires explicit `id-token: write`; that permission alone does not grant access to external resources. The Worker must still validate claims and enforce its own least-privilege policy. [GitHub OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)

## Client downloads and package validation

- Use HTTPS for API, assets, and repository sources. Reject `file:`, `data:`, and arbitrary schemes; reject URLs with username/password; constrain redirects and require HTTPS at every hop.
- The app has an explicit package-size/storage ceiling. Compare received bytes to the manifest `size`; reject mismatch before archive processing.
- Verify SHA-256 before handing any package to an installation backend. A mismatch cancels installation and displays a short explanation. Keep the computed and expected digests in a local diagnostic record without leaking signed download URLs.
- Treat checksum as integrity relative to the digest source, not as a safety certificate or publisher identity. If the repository/API is compromised, both package and expected digest could be replaced. Present source identity and user trust context; do not label a package "safe" merely because its hash matches.
- Parse archives under explicit resource ceilings: archive bytes, expanded bytes, compression ratio, entry count, path depth, metadata entry size, and elapsed work. Reject traversal, links/special files, duplicate normalized entries, and unexpected archive layouts. Read only the required metadata when possible; never extract to an attacker-selected path.
- Show a source trust warning before adding third-party repositories and a neutral verification statement on details/install sheets. “Verified” means hash and metadata matched, not malware-free or Apple-approved.

Repository manifests are fetched by the client from their declared HTTPS origin, not proxied through the server, preventing arbitrary source URLs from becoming server-side request forgery targets. Validate JSON size, schema version, field lengths, collection counts, image response sizes, and URL schemes. Render text as text, never as injected HTML.

## API, storage, and database controls

- Public DTOs are allowlisted projections. Admin/internal fields, R2 keys, session identifiers, and validator details are never selected into public responses.
- Use prepared D1 statements, schema constraints, bounded pagination, indexed filters, request-body limits, explicit CORS, and stable error codes. Return generic authentication errors and a request ID, not secret-bearing diagnostics.
- R2 staging is private; public R2 contains only released objects with immutable keys. Validate custom-domain origin configuration, MIME type, `Content-Disposition`, cache headers, and byte-range support.
- Keep API, CDN, and admin origins separate. Exact-origin credentialed CORS and `SameSite=Lax` cookies are designed for subdomains of one registrable site; production must use HTTPS for every hostname.
- Configure retention for sessions, audit metadata, failed uploads, and local caches. Catalog text and download history should not include device identifiers unless a later feature provides a clear need and privacy disclosure.
- Use HTTPS, dependency lockfiles, automated dependency/license inventory, secret scanning, and CI permission minimization. No production keys or IPA packages belong in Git.

## Integrity and future publisher signatures

V1 stores and verifies SHA-256, release size, bundle ID, version/build, and upload timestamp. The hash detects a mismatched file against published metadata. It does not stop a malicious repository owner, compromised API administrator, or compromised signing/storage account from publishing a new package and a matching hash.

Before broad third-party distribution, add signed repository metadata with public-key pinning and a documented rotation/revocation mechanism. A private signing key must stay in an operator-controlled secret store and never ship in the app. This Phase 0 format does not yet specify canonical signed bytes; the signing format is a separate ADR before it becomes a trust promise.

## Cost and operational limits

Free Cloudflare Workers allow 10 ms CPU per request. Cloudflare R2 includes a finite monthly free storage/operation allowance and charges for overage at current listed rates. D1 Free has hard daily query limits. GitHub-hosted standard Linux runners are free when the repository is public; private repository use consumes included quota and may become billable. Do not change plans, add larger runners, create production resources, or exceed budgeted quotas automatically.

Current references: [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/), [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/), [D1 limits](https://developers.cloudflare.com/d1/platform/limits/), [R2 pricing](https://developers.cloudflare.com/r2/pricing/), and [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions). Recheck before deployment because quotas and product rules can change.

## Incident response baseline

Provide operator procedures for disabling publishing, revoking sessions, invalidating/replacing presigned capabilities, unpublishing a release, preserving audit evidence, rotating Worker secrets, and publishing a corrected immutable version. A compromised validator or metadata API requires a new release record and digest; do not silently mutate already distributed package bytes.
