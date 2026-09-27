# Isolated IPA validator

Production IPA validation runs in `.github/workflows/validate-ipa.yml`, not in the Worker request, Admin browser, or production database process. `scripts/validate_ipa.py` reads the package as untrusted ZIP data and never extracts or executes its contents.

## Workflow trust model

The workflow is manually dispatched by the API through a GitHub App that is limited to the target repository and `actions: write`. Inputs contain only a UUID upload ID and a random one-use dispatch ticket. The Worker stores only the ticket hash. The lease job has `id-token: write` and uses GitHub OIDC to ask the API for a lease. OIDC claims are verified against GitHub's official JWKS with exact issuer, audience, repository, branch ref, workflow file/ref, event, run ID and attempt checks.

The lease response contains one short-lived, signed HTTPS GET URL scoped to one private staging object, its expected size and a nonce. The inspection job has only `contents: read`: it has no OIDC, R2 credentials, GitHub App key or Worker secret. It refuses redirects and downloads only the R2 URL issued for this run. A separate result job has OIDC permission and can submit only the report bound to that run and nonce. The ticket and nonce are single-use.

```text
Lease (OIDC, ticket) → Inspect (no credentials) → Report (OIDC, nonce)
```

GitHub's workflow ID token is an identity input, not authorization by itself. The API validates every required claim and ties that identity to a particular upload transition. Client JSON such as `{ "result": "passed" }` is never accepted without that authenticated workflow identity.

## What the parser checks

- Package file and ZIP end-of-central-directory structures are well-formed and within the expected byte count and 1 GiB package cap.
- Central directory is capped before entry iteration; ZIP64, encrypted members, malformed/duplicate paths, absolute paths, `..`, path depth, symlink/special-file entries and unsupported compression are rejected.
- Entry count, total declared uncompressed bytes, per-entry size and compression ratio are bounded to mitigate zip bombs. Nothing is extracted to disk, so archive paths cannot write outside a temporary folder.
- Exactly one expected `Payload/*.app/Info.plist` is selected; Info.plist must be bounded XML plist data with valid required strings, reverse-DNS bundle ID, semantic version/build, minimum OS, and a corresponding executable member.
- The runner computes SHA-256 from package bytes itself. It returns only bounded metadata, result and digest.

The result is structural package metadata validation, not a malware scan, signature-policy decision, Apple approval, source review or legal determination. Admin review checks metadata and records the publisher's rights attestation separately.

## Operator configuration (not applied in this phase)

### GitHub repository variables

- `DREYZESTORE_API_BASE_URL`: HTTPS API origin, with no path, query, credentials or port.
- `DREYZESTORE_VALIDATOR_AUDIENCE`: exact audience configured in the Worker.

### Worker variables

- `GITHUB_OWNER`, `GITHUB_REPOSITORY`, `GITHUB_VALIDATOR_WORKFLOW`, `GITHUB_VALIDATOR_REF`.
- `VALIDATOR_API_BASE_URL`, `VALIDATOR_OIDC_AUDIENCE`, `VALIDATOR_OIDC_JWKS_URL` (official GitHub URL only).
- `STAGING_BUCKET_NAME`, `PUBLIC_BUCKET_NAME`, `PUBLIC_ASSETS_BASE_URL`, `PUBLIC_API_BASE_URL`.
- `R2_ACCOUNT_ID`, `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`.

### Worker secrets

- `GITHUB_APP_PRIVATE_KEY`.
- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` scoped to the exact buckets.
- `ADMIN_CSRF_SECRET`, `ADMIN_RATE_LIMIT_HMAC_KEY`.

Do not put Cloudflare credentials in GitHub Actions. The only secrets available to the API are configured in the Worker secret store; the parser job receives none. Do not add secrets to YAML, repository variables, build artifacts or logs. The repo does not contain real values.

Pin Actions to reviewed full commit SHAs, keep the validator workflow on a protected default branch, and do not accept a user-supplied ref or URL. The current workflow uses standard GitHub-hosted runners for this public repository; do not switch to larger runners without cost review.

## Result and retry behavior

A valid result moves `validating` to `ready_for_review`; a package rejection or bounded inspection failure moves it to `validation_failed`. If the inspect job fails unexpectedly after a lease, a separate OIDC report job marks the validation failure. If the lease job fails before a report nonce exists, the upload remains queued and must be retried or re-uploaded before its expiry. No failed path can publish.

## Local test harness

`npm run admin:e2e:local` generates a tiny authorized test ZIP/IPA in a temporary directory, writes it to a test R2-compatible bucket, executes the real Python parser, sends its metadata through the Hono callback path using an ephemeral test signing key, publishes, and verifies the public API/repository/download digest. The test does not commit a package. The `TEST_FETCH` and test validator key seams exist only in tests and are not configured in Wrangler.
