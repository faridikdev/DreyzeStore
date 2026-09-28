# Security architecture and threat model

**Scope:** Admin authentication and release publishing, public catalog delivery, the iOS package-verification boundary, the Windows Companion signing boundary, and Phase 8 RC packaging/recovery. This is an engineering baseline, not a malware scan, legal opinion, or independent security certification.

## Assets and trust boundaries

| Asset | Boundary | Security controls |
|---|---|---|
| Admin account/password | Admin browser → Hono API → internal KDF Durable Object | Argon2id, rate limits, opaque sessions, CSRF, role checks, audit events |
| Session/CSRF | Browser and D1 | Cookie is HttpOnly/Secure in production/SameSite=Lax; D1 stores only hashes |
| IPA awaiting review | Browser → private R2 staging → isolated GitHub runner | Per-object short-lived signed PUT/GET URLs, size caps, one-run ticket and OIDC identity |
| Validation report | GitHub OIDC workflow → API | GitHub JWKS signature, exact issuer/audience/repository/ref/workflow/event, run ID/attempt, one-use nonce |
| Published IPA/assets | Public R2/CDN | Immutable keys; written only after validation/review/rights attestation and D1 transition |
| Catalog records/digest | D1 → public API/repository | Allowlisted public DTOs, schema validation, client independently checks digest and package metadata |
| Temporary client package | iOS app sandbox | Managed UUID path; SHA-256 then bounded IPA inspection; installation APIs only accept `VerifiedPackage` |

Threats considered include password guessing, session theft, CSRF, role escalation, fake/replayed validator callbacks, staging URL disclosure, archive traversal/zip bombs, invalid or malicious images, broken object isolation, metadata mismatch, unauthorized distribution, race conditions during publish, and accidental leakage of internal keys or audit data.

The separate Windows Companion threat model is available in [DreyzeStore-threat-model.md](../DreyzeStore-threat-model.md); Windows local pairing, device, signing, and transfer controls are summarized in [windows-companion-security.md](windows-companion-security.md).

## Admin authentication

- New credentials use Argon2id v1 (`m=19,456 KiB`, `t=2`, `p=1`, 32-byte random salt and output). The KDF is from the MIT-licensed `argon2id` WebAssembly package and is statically imported into the internal `AdminPasswordKdf` Durable Object. The object has no HTTP route and its namespace is only bound to the API Worker.
- The choice of Durable Object is a technical runtime boundary: Cloudflare's production Workers WebCrypto PBKDF2 path rejects high iteration counts (see the [official workerd issue](https://github.com/cloudflare/workerd/issues/1346)); local emulation alone would not expose this. Durable Objects support JavaScript/Wasm and have an independent per-invocation CPU budget ([limits](https://developers.cloudflare.com/durable-objects/platform/limits/)). Confirm quotas and latency on the chosen plan before deployment.
- Migration 0004 preserves existing bounded PBKDF2 rows for backward compatibility. A valid login rehashes the credential to Argon2id; malformed or out-of-bound KDF parameters are rejected. Bootstrap creates a random password and stores only the Argon2id digest. No password is committed or logged.
- Login rate limits are HMAC-keyed by normalized email and source IP in D1; the API returns a generic credential error. An opaque random cookie token is returned once; D1 stores only its SHA-256. Production cookie flags are `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`, and an eight-hour maximum age. Logout revokes the D1 session.
- Mutating routes require an allowlisted exact `Origin` and HMAC-derived CSRF token. `requireAdmin` protects admin routes; `requireRole("admin")` protects publish/reject/unpublish/delete. UI hiding is not an authorization boundary.
- Only the initial admin bootstrap utility creates a password account. It generates a one-time password and can target local D1 by default; remote use requires a database-name confirmation. It does not set secrets or deploy anything.

## Upload and validator trust

- IPA and images are uploaded directly to private R2 staging using a signed, short-lived, single-object URL. The API stores server-generated object keys, not client filenames. The Admin browser cannot mark validation as passed.
- A Worker receives only the upload ID and issues a GitHub workflow dispatch with a random one-use ticket. The GitHub App private key remains a Worker secret. The validator workflow's inspection job receives no Cloudflare secret and no OIDC permission; its code does not execute package contents.
- Before staging bytes are read or a report accepted, the API verifies GitHub OIDC signature against the official JWKS and requires the expected audience, issuer, repository, branch ref, workflow file/ref, `workflow_dispatch` event, run identity, report nonce, and one-use state transition. OIDC permission alone grants no app authorization.
- The validator downloads only the upload's private signed R2 URL, refuses redirects, caps package bytes and ZIP central-directory/entry/expanded-size/compression-ratio limits, rejects traversal/absolute paths/symlinks/encryption/unsupported ZIP64, and reads only the IPA Info.plist and executable metadata. It never extracts files or runs package code.
- An inspection failure is reported through the same authenticated workflow identity and changes the job to `validation_failed`; an infrastructure failure before a validation lease is issued leaves the upload queued for an operator retry/re-upload. A validation result is not a malware verdict.
- Publishing requires exact app bundle ID and actual size match, successful server-side validation, a saved review, a publish-capable admin, and a versioned distribution-rights attestation. It writes an immutable published object, then commits the D1 release/attestation/audit transition; failed D1 commit compensates by deleting the just-copied object. Client validation is still mandatory after download.

## Assets, API, and storage

- Image uploads allow PNG/JPEG only, with byte-signature/structure/CRC/dimension/size checks and a count limit. Content-Type is not trusted by itself. The original verified bytes are stored; they are not re-encoded or malware-scanned.
- Staging is private and never appears in public DTOs. Public package object keys are random/normalized and immutable. Rejected and expired staging objects are removed when their state changes; production cleanup/retention scheduling remains an operator task.
- Public endpoints use prepared SQL, field allowlists, bounded pagination and request sizes, schema validation, cache policy/ETags, and a common error envelope. Admin endpoints use `no-store`. CORS reflects only exact configured Admin origins; it is not `*`.
- Presigned R2 URLs are bearer capabilities. Do not print them in logs, GitHub step output, user telemetry, or audit metadata. The workflow keeps the URL in an output only between its isolated lease and inspection jobs; the capability is object-specific, short-lived, and read-only.
- Audit rows record action, actor, resource, request ID, timestamp and masked IP metadata. Passwords, cookies, tokens, secrets, presigned URLs and package bytes are excluded.

## Client and distribution trust

- The client accepts only HTTPS package URLs, checks the exact byte limit, SHA-256, ZIP structure, bundle ID/version/build/minimum OS and executable before `VerifiedPackage` creation. A digest match confirms integrity relative to the API/repository, not safety or publisher identity.
- Immediately before installation, the iOS coordinator repeats the Phase 4 managed-path, SHA-256, archive, and release-metadata checks. For the stock-iOS Windows Companion route, the local Windows validator repeats these checks again before signing; Companion reports `Installed` only after device inventory confirms the exact bundle ID/version/build. The optional TrollStore document-import path still reports `Handed Off` because DreyzeStore cannot observe its install result.
- The rights checkbox records who asserted distribution rights, when, for which release and attestation version. It is not proof that the assertion is true; maintainers must review source authorization independently.

## Windows Companion and local signing

- The Windows service binds to a selected private LAN address, presents a locally generated TLS certificate, and the iOS client pins its exact SHA-256 certificate fingerprint from QR/manual pairing data. Pair codes are short-lived and one-use; the paired bearer token is stored in iOS Keychain and only its hash is stored in Windows Credential Manager.
- All routes except one-use pairing require the paired bearer token, the paired iPhone's client ID, a fresh timestamp, and a unique nonce. Pairing is rate-limited. The API accepts only streamed IPA bytes plus validated release metadata, never a client-selected filesystem path or URL; body length is capped.
- The companion validates the iPhone's UDID before accepting/streaming a package. It rechecks the package digest, archive limits, bundle ID, version, build, and minimum OS locally. Signing/install uses a UUID-managed workspace; the zsign password is sent through a length-prefixed stdin pipe, not command-line arguments or environment variables. Process arguments use an argv API rather than a shell.
- Apple credentials never leave the PC. P12 and provisioning profile bytes use Windows DPAPI; P12 password uses Windows Credential Manager. A temporary P12 file is still required by zsign and is deleted after use; deletion is not guaranteed secure erasure on SSDs or through filesystem snapshots. A stolen unlocked Windows account remains in scope.
- Windows CryptoAPI opens an imported P12 with `PKCS12_NO_PERSIST_KEY` for local certificate expiry/matching inspection. The P12 private key is not returned to UI or sent to any service. Diagnostic output contains check statuses/details only; the local test-install record contains bundle ID, version/build, digest, team, expiry, timestamp, and UDID reference.
- The local Test Installation button only accepts a user-selected package under the reserved project test bundle-ID prefix `org.dreyzestore.test.*`. It re-inspects the IPA and establishes the expected SHA-256 from the selected file, then the common coordinator revalidates the file before signing and confirms installation from inventory. This is a hardware-test-only local import path, not a network/API path around iOS `VerifiedPackage` verification. Its uninstall is scoped to the recorded test bundle and requires inventory confirmation.
- The CI DreyzeStore RC device-test artifact uses `org.dreyzestore.test.store` and enters the same local test-install allowlist. It is unsigned and must be checked against its CI SHA-256 manifest before selection. It cannot access a production catalog because the CI API URL is intentionally reserved; a device-test build with an approved HTTPS endpoint must be built separately.
- Apple Account, 2FA, session, and App Store Connect API-key fields do not exist. The app does not use Apple private authentication APIs or third-party Anisette hosts. Developer Mode and entitlement compatibility are not inferred from missing device/provider data.
- `Installed` is returned only after the USB install command completes and a fresh device inventory contains the same bundle ID, version, and build. `Uninstalled` is returned only after the app disappears from inventory. Companion-local records are records of this tool's verified operation, not proof that the app remains installed later.
- A source IPA signature/hash does not imply safety. Re-signing changes the package hash and signature; the companion records both original and signed digests. Provisioning compatibility, entitlements, extensions, device trust, Developer Mode, and Apple expiry rules can still reject installation or affect app updates/data preservation.
- The Windows service is local only. Do not expose its port through public firewall rules, reverse proxies, router forwarding, or a public interface. Pair only on a trusted private LAN and remove an unused pairing from both endpoints.

## Deployment requirements and limits

Never set `LOCAL_UPLOADS_ENABLED=true` or `LOCAL_VALIDATOR_ENABLED=true` on an internet-facing Worker. Keep GitHub App/R2/HMAC secrets in provider secret storage and client configuration out of Git. Do not store Apple credentials or signing keys in DreyzeStore. Production deployment, DNS, paid resources, usage-plan changes and domain purchase are outside this phase.

Cloudflare usage quotas and CPU/runtime behavior change; check official [Worker limits](https://developers.cloudflare.com/workers/platform/limits/), [Durable Object limits](https://developers.cloudflare.com/durable-objects/platform/limits/), [Durable Object pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/), [D1 limits](https://developers.cloudflare.com/d1/platform/limits/), [R2 pricing](https://developers.cloudflare.com/r2/pricing/), and [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) before deployment. Configure budgets/alerts and test quota failure paths before enabling publishing.
