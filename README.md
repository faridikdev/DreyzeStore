# DreyzeStore

[English](README.md) · [Русский](README.ru.md)

DreyzeStore is an open-source native iOS catalog, package verification client, Cloudflare Workers API, repository format, and administrator publishing panel. The project is developed in phases. **Phase 6 adds password-authenticated administration, app drafts, private IPA staging, isolated server validation, rights attestation, and reviewed release publishing.**

The iOS client downloads and verifies published packages, then can hand a `VerifiedPackage` to TrollStore through Apple's document import route on compatible devices. DreyzeStore records that as **Handed Off**; it cannot confirm the receiver's installation. Standard sandboxed iOS still cannot install arbitrary IPA files or enumerate all installed apps.

## Architecture

- `ios/DreyzeStore` — SwiftUI client (iOS 16+), typed async API, offline metadata cache, package downloads, SHA-256 and IPA validation, and verified document handoff.
- `backend` — Cloudflare Worker with Hono, TypeScript, D1 metadata, private R2 staging, and a public R2 distribution bucket.
- `admin` — React/TypeScript/Vite responsive panel for app drafts, asset uploads, release review, featured content, and publishing.
- `shared/schemas` — versioned repository JSON Schema and shared DTO validation.
- `scripts/validate_ipa.py` — isolated, bounded IPA metadata validator used by the GitHub Actions validator workflow.
- `.github/workflows/ci.yml` — backend/admin checks and macOS iOS simulator build/tests. `.github/workflows/validate-ipa.yml` — OIDC-authenticated, per-upload validation workflow.

See [architecture](docs/architecture.md), [API](docs/api.md), [admin operations](docs/admin.md), [bootstrap](docs/admin-bootstrap.md), [upload pipeline](docs/upload-pipeline.md), [validator](docs/validator.md), [security](docs/security.md), [installation](docs/installation.md), [licenses](docs/licenses.md), and [deployment boundaries](docs/deployment.md).

## Requirements

- Node.js 22.12+ and npm.
- Python 3 for package validation and migration checks.
- macOS and Xcode for a local iOS build; public GitHub Actions runs the simulator build on macOS.
- Cloudflare credentials are not needed for local catalog development or tests. Production resources are not created by setup or CI.

## Local backend and admin

```sh
npm ci
npm run db:migrate:local
npm run db:seed:local
npm run dev:api
```

In a second terminal, configure the Vite panel and start it:

```sh
Copy-Item admin/.env.example admin/.env.local # PowerShell
npm run dev:admin
```

Local D1 seed records are fictional and use reserved `.invalid` asset/package URLs. A generated IPA fixture exists only during tests. For an end-to-end publishing exercise, run `npm run admin:e2e:local`; it uses an in-memory D1/R2-compatible test harness, the real Python validator, and the same Hono endpoints without storing an IPA in Git. To create a local sign-in, apply migrations and use `npm run admin:bootstrap:local -- --email=you@example.test`; the random password is printed once.

Copy `backend/.dev.vars.example` to `backend/.dev.vars` for local authentication/upload flags, and `admin/.env.example` to `admin/.env.local` for the panel URL. The production-style validation path requires the GitHub App and workflow settings documented in [validator setup](docs/validator.md). No production credentials are present in the repository.

## iOS

Open `ios/DreyzeStore/DreyzeStore.xcodeproj` in Xcode or run on macOS:

```sh
xcodebuild test -project ios/DreyzeStore/DreyzeStore.xcodeproj -scheme DreyzeStore \
  -destination 'platform=iOS Simulator,name=<available iPhone>' CODE_SIGNING_ALLOWED=NO
```

The Debug configuration targets `http://127.0.0.1:8787/api/v1`. Release configuration remains pointed at a reserved `.invalid` host until an operator configures an approved public endpoint.

## Security and release rights

Admin passwords are Argon2id-hashed in an internal Durable Object KDF. Sessions use hashed opaque tokens in D1 and HttpOnly cookies; writes require CSRF validation. IPA bytes stay in private staging until a pinned GitHub Actions workflow validates the package and an administrator reviews metadata and attests to distribution rights. Published objects have immutable keys. Client-side SHA-256 and package validation still run after download.

A matching SHA-256 confirms integrity against the published digest; it does not establish that software is safe, lawful, or malware-free. The MIT project license grants no rights to application packages, icons, screenshots, or repository content.

## Checks

```sh
npm run check
npm run admin:e2e:local
```

The full check includes lint, TypeScript checks, tests, Python validator tests, migration validation, and an Admin build plus Wrangler Worker dry-run. No deployment, paid resource creation, DNS change, or production secret setup is part of these commands.
