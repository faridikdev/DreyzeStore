# Backend development

The API is a versioned Hono application running on Cloudflare Workers. Request handlers validate HTTP inputs and delegate to services; services implement catalog, auth, asset and publishing rules; repositories own D1 SQL. D1 is the metadata source of truth. R2 bindings separate private staging from published packages and public artwork.

## Local API

```sh
npm ci
npm run db:migrate:local
npm run db:seed:local
npm run dev:api
```

Wrangler uses local D1/R2 emulation and the `AdminPasswordKdf` Durable Object binding. The SQL seed contains fictional metadata and `.invalid` URLs; it contains no package. `backend/.dev.vars.example` contains local-only placeholders. Copy it to `backend/.dev.vars` to enable local-only upload endpoints; never copy its values into production.

The API is documented in [api.md](api.md). Public responses are allowlisted; drafts, unpublished releases, R2 keys, session data, rights attestations, validator state, and audit rows are not returned by public catalog endpoints. Catalog responses use bounded cache headers/ETags; account and update responses are `no-store`.

## Services and security boundaries

- `routes/` — HTTP endpoint and body/query validation.
- `services/` — catalog reads, password/session auth, assets, R2 upload URLs, upload state transitions, review and publish.
- `repositories/` — prepared D1 statements and conditional state changes.
- `security/` — CSRF, session cookies, role checks, OIDC, capability token hashing and password KDF client.
- `passwordKdfDo.ts` — an internal, non-routed Durable Object that runs Argon2id from statically bundled upstream WebAssembly. Password text is sent only through the Workers internal object binding; it is never written to D1 or audit logs.

Workers production WebCrypto rejects PBKDF2 derivations above the runtime's limit, so the original 600,000-iteration browser-independent PBKDF2 approach would fail at login. New accounts use Argon2id (`m=19,456 KiB`, `t=2`, `p=1`) in the KDF Durable Object. Existing bounded PBKDF2 credential rows are preserved by migration 0004 and rehashed to Argon2id after the next successful login. See [ADR 0003](adr/0003-admin-password-kdf.md).

## D1 and R2

Migrations are append-only in `backend/migrations/`. `python scripts/validate_migrations.py` applies them in a temporary SQLite database and checks constraints, indexes, foreign keys, FTS search, seed exposure, and migration of a legacy password row. `0004_argon2id_admin_credentials.sql` changes credential parameters without discarding existing hashes.

Private R2 staging contains only server-generated `staging/{uuid}/package.ipa` and `staging-assets/{uuid}/asset` keys. The public bucket receives a package only after validation, review, and rights attestation; release keys include normalized bundle ID, version, and digest. Client filename never affects an object key. See [upload pipeline](upload-pipeline.md).

## Validation and build commands

From the root, `npm run check` runs lint/typecheck/tests, Python package-validator tests, migration validation, Admin production build, and a Wrangler `--dry-run` Worker bundle. `npm run admin:e2e:local` runs the end-to-end test against in-memory D1/R2-compatible adapters and the Python validator. Neither command contacts production Cloudflare.

Real direct R2 upload and external GitHub Actions validation require operator-provisioned bindings and secrets; the repo contains only local names/placeholders. No Worker deploy or account resource setup is included in development commands.
