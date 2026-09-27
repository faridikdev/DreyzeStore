# Deployment boundaries

**PHASE 6 does not deploy the Worker or Admin, create Cloudflare resources, configure DNS, or set production secrets.** `backend/wrangler.jsonc` is prepared for bindings but uses a placeholder D1 ID and local bucket names. `npm run build --workspace @dreyzestore/api` performs Wrangler `--dry-run` bundling only.

## Required bindings and configuration

An operator preparing a later deployment must provision and review these resources independently:

- D1 metadata database with all checked-in migrations applied in order.
- Private R2 staging bucket and public distribution/assets bucket. Configure exact admin-origin CORS for staging `PUT` and required signed headers; do not enable public access to staging.
- `PASSWORD_KDF` binding and `AdminPasswordKdf` class migration. This CPU-heavy password hashing runs inside a Durable Object and must be exercised on the selected Cloudflare plan before production use.
- An HTTPS API origin, HTTPS asset/package origin, and exact Admin origin. Repository package URLs use the public CDN origin; they never address staging.
- GitHub App installation limited to the repository's Actions workflow dispatch permission and the validator workflow on the protected default branch.

Non-secret Worker variables are documented in [validator setup](validator.md) and [admin operations](admin.md). Secrets are names only in `.dev.vars.example`; production values must be entered through the provider secret store, never checked in or baked into the Admin build.

## Free-tier and cost boundary

No Cloudflare plan upgrade, larger runner, paid service, domain purchase, or resource creation is authorized by this phase. Cloudflare's Durable Objects have plan-specific request/compute/storage quotas. The deployment owner must verify current limits and set budget/usage alerts before enabling the Admin surface; a quota failure must fail closed and prevent publishing. Public GitHub-hosted runners are used by the validator workflow; do not switch to larger or self-hosted runners without review.

## Before any deployment

1. Review current Cloudflare and GitHub pricing/quotas. Free-tier behavior and product limits can change.
2. Select the exact production database, buckets, domains, GitHub App, and CORS origins; review all state-changing commands.
3. Apply migrations against the intended database and verify each migration result. Do not target production with local seed/bootstrap commands by mistake.
4. Create the initial administrator using the explicit remote confirmation flow in [admin bootstrap](admin-bootstrap.md); securely record the generated password once.
5. Set secrets by provider secret store, configure all required Worker vars, then verify login, CSRF, upload, validator OIDC, R2 isolation, publish and client download in a staging environment.
6. Obtain a separate explicit deployment approval before any production deploy, DNS change, resource creation, or paid action.

There is no production deploy action in CI. CI uses standard GitHub-hosted runners for public repository jobs, local SQLite migration validation, static Admin build, and Wrangler dry-run.
