# DreyzeStore architecture

**Status:** Phase 2 backend complete. The repository includes the iOS shell, read-only catalog API on the local Cloudflare Worker stack, repository-v1 generation/validation, local D1 migrations and seed, admin shell, and CI. No cloud resources have been created. This document records both the current implementation and the longer-term target; anything marked future-phase is not a live feature.

## Goals and platform boundary

DreyzeStore is a native SwiftUI catalog and package manager with a separate metadata API, object storage, repository format, and web administration client. It can always browse, cache, download, and verify packages. Installing a verified IPA is conditional on an installation mechanism that the OS and the device actually make available.

An ordinary sandboxed iOS app does not get a general-purpose API to install arbitrary IPA files or enumerate every installed third-party app. The client must therefore report **Downloaded** or **Verified** until an installation backend provides evidence of an installation. It must not turn a successful download, URL handoff, or button tap into **Installed**.

## Proposed monorepo boundaries

```text
ios/DreyzeStore/       Native SwiftUI client
backend/               Hono API Worker, D1 migrations, validation dispatch
admin/                 React + TypeScript + Vite administration SPA
shared/schemas/        Versioned JSON Schema and shared contract fixtures
scripts/               Local setup, schema and release tooling
docs/                  Architecture, operations, security, and format docs
.github/workflows/     CI and isolated package validation jobs
```

The admin app is a static SPA because it has no public pages that need server-side rendering. The API remains the only authority for accounts, permissions, metadata, and release state. This avoids adding a second application server for the admin panel.

## System shape

This is the target system shape. In Phase 2, only the public catalog metadata API and local D1 seed are implemented; admin auth, package transfer/validation, installation, and production storage are later work.

```mermaid
flowchart LR
  IOS[iOS SwiftUI client] -->|catalog, search, details| API[Hono API on Cloudflare Workers]
  API --> D1[(Cloudflare D1 metadata)]
  IOS -->|official repository manifest| API
  IOS -->|public IPA and image downloads| R2[(Cloudflare R2 public assets)]
  ADMIN[React/Vite admin SPA] -->|session and admin API| API
  ADMIN -->|short-lived upload capability| API
  ADMIN -->|direct upload| STAGE[(Private R2 staging bucket)]
  API -->|dispatch upload ID| GH[GitHub Actions validator]
  GH -->|temporary read lease; verified metadata| API
  API -->|promote immutable package after review| R2
  IOS -->|user-added HTTPS sources| REPOS[Third-party repository hosts]
```

The public package bucket contains only published releases. A separate private R2 bucket holds pending uploads. R2 presigned URLs are short-lived bearer capabilities, limited to one object and one operation; the app bundle, admin JavaScript, logs, and API responses must never contain R2 credentials.

### Upload and publication state

```text
created -> uploading -> queued -> validating -> validated -> published
                                      |                |
                                      +-> rejected     +-> rejected by admin
```

1. An authenticated admin creates a draft and requests an upload ticket.
2. The browser sends the bytes directly to a private staging object using temporary upload URLs. Large uploads use R2 multipart operations.
3. The API dispatches an upload ID, not the IPA or a bearer URL, to a trusted workflow on the default branch.
4. An isolated standard Linux runner fetches the staged object through a short-lived, read-only lease. It computes SHA-256, inspects ZIP entries and IPA metadata, and emits a bounded metadata report. It never executes IPA contents or receives signing keys.
5. A separate, minimal reporting job obtains a GitHub OIDC token. The Worker accepts the report only when the token's issuer, audience, repository, workflow identity, and protected ref match the configured validator. The parser job has no cloud credential or OIDC permission.
6. The API compares the report with the admin's intended app and creates a **validated draft release**. The admin reviews bundle ID, version, size, and checksum before publishing.
7. On publish, the Worker copies the immutable staged object to the public R2 bucket, inserts release metadata, and records an audit event. Rejected, expired, and abandoned stage objects are removed by lifecycle cleanup.

This keeps large-file transfer and archive parsing outside the Workers Free request path. GitHub documents standard hosted runner use as free for public repositories; private repositories draw against an account allowance and can incur charges after it is exhausted. The design assumes the open-source repository is public and standard Linux runners are used. If that assumption changes, the validator must pause when free capacity is unavailable; it must not enable billing or switch to larger runners automatically. See [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) and [GitHub OIDC](https://docs.github.com/en/actions/concepts/security/openid-connect).

## Cloud architecture

| Concern | Decision | Boundary |
|---|---|---|
| API | TypeScript + Hono on Cloudflare Workers | Stateless routes; environment bindings for D1/R2; never trusts client-supplied package metadata |
| Metadata | Cloudflare D1 | SQLite-compatible relational metadata, migrations, indexes, sessions, audit records |
| Packages and media | Cloudflare R2 | Separate private staging and public immutable release/assets buckets |
| Admin | React + TypeScript + Vite SPA | Static UI; secure session and every permission check live in the API |
| Package validation | GitHub Actions standard Ubuntu runner for a public repository | No IPA in Git, workflow artifacts, or logs; no IPA code execution |
| CDN | R2 custom domain for published, public objects | HTTPS; URLs are generated from server-controlled object keys |
| Local development | Wrangler local D1/R2 bindings and local admin/client configuration | No Cloudflare account, domain, or production data required |

This keeps the requested Workers/Hono/D1/R2 architecture. It adds GitHub Actions only for the workload the current Workers Free CPU limit is unsuitable for. Cloudflare documents 10 ms CPU per Free Worker invocation and a 100 MB maximum incoming request body on its Free account plan; large uploads are sent directly to R2, and archive parsing/hash work runs in the validator instead. [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)

Cloudflare's current R2 Free allowance is 10 GB-month storage, 1 million Class A operations, and 10 million Class B operations per month, with no egress charge. Usage beyond included allowances is billable. Workers Paid has a $5/month minimum. Phase 0 provisions nothing; later deployment must stay within free allowances or stop before activating paid services. [R2 pricing](https://developers.cloudflare.com/r2/pricing/), [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)

Production hostnames are `api.<owned-domain>`, `admin.<owned-domain>`, and `cdn.<owned-domain>`. Development uses local Worker URLs. No domain, DNS record, account, secret, or production service is created as part of this phase.

## REST API contract

Base path: `/api/v1`. JSON uses UTF-8 and camelCase fields. IDs are stable identifiers. Public APIs return only published records and never expose R2 object-key fields, admin fields, or storage credentials. The implemented API reference, request examples, response examples, limits, caching, and errors are in [api.md](api.md).

Success envelope:

```json
{
  "data": {},
  "meta": { "page": 1, "pageSize": 24, "hasMore": false }
}
```

Successful responses include `X-Request-Id` in the response headers. Errors include the request ID in the error object.

Error envelope:

```json
{
  "error": {
    "code": "invalid_query",
    "message": "The search query is invalid.",
    "requestId": "req_..."
  }
}
```

Do not include stack traces, passwords, cookies, presigned URLs, or raw tokens in errors. `details` may carry field-level validation messages. Cacheable public responses use ETag/conditional requests; authenticated admin responses use `Cache-Control: no-store`.

| Route | Phase 2 contract |
|---|---|
| `GET /apps?category=&repository=&sort=&page=&limit=&cursor=` | Published app summaries; sort is `name`, `updated`, or `newest`; page up to 1000 and page size up to 100, or a filter-bound cursor. |
| `GET /apps/:id` | Published app detail, developer, category, latest published stable release (or newest available release), screenshots, and compatibility metadata. |
| `GET /apps/:id/versions` | Published release history, newest publication timestamp first. |
| `GET /categories` | Canonical categories and counts of published apps. |
| `GET /featured` | Ordered configured sections with published apps only. |
| `GET /search?q=&category=&repository=&sort=&page=&limit=&cursor=` | D1 FTS search across name, developer, bundle ID, description, and category. |
| `GET /updates?apps=` | Up to 25 unique installed app/version pairs; returns newer published stable releases by semantic precedence. Does not discover installed apps. |
| `GET /repository` | Public repository-v1 document generated from published rows and checked by the shared validator. |
| `GET /health` | D1 readiness without exposing diagnostics. |

All Phase 2 routes are read-only. Admin auth/CRUD, uploads, downloads, and package streaming are not implemented. Query/path input is validated before D1 access; values use prepared statements; public responses use explicit DTO projections; shared errors include a request ID. Public catalog responses use bounded `ETag` caching, and updates responses are `no-store` because the request contains installed-app inventory. CORS reflects only exact configured origins.

Version comparison uses semantic components and prerelease ordering, never string comparison: `1.0 < 1.1`, `1.9 < 1.10`, and `2.0-beta < 2.0`. Preserve the original version/build strings for display. For legacy two-component versions, compare the missing patch component as zero. A release's bundle identifier must match the app record and its `Info.plist`.

## D1 data model

Initial normalized tables and constraints:

| Table | Purpose and important indexes |
|---|---|
| `developers` | Display name and optional public links; unique stable ID. |
| `categories` | Stable slug and localized display name; unique slug. |
| `apps` | Stable ID, unique bundle ID, developer/category/repository foreign keys, bounded text/media references, publication/deletion timestamps; catalog name/category/source/date indexes. |
| `versions` | App FK, version/build, minimum OS, R2 object reference, SHA-256, byte size, release notes, channel and publication timestamp; unique `(app_id, version, build)` and published-release index. |
| `screenshots` | App FK, R2 asset reference, order and accessibility caption; index `(app_id, ordinal)`. |
| `featured` | Section key, app FK, rank and optional date window; ordered index and unique app-per-section constraint. |
| `app_daily_downloads` | Reserved daily download-request aggregate; not used for catalog sorting in Phase 2. |
| `repositories` | Identifier, manifest URL, trust level, description/icon reference and timestamps; unique identifier/URL and a single official repository. |
| `admin_users` | External identity subject, role, enabled state, creation/last-auth times; unique `(provider, subject)`. No plaintext password field. |
| `admin_sessions` | Hash of random opaque session token, user FK, CSRF-token hash, expiry/revocation; unique token hash. |
| `audit_logs` | Actor FK/snapshot, action, resource type/id, timestamp, request ID, pseudonymous IP metadata; indexed by time and resource. Never stores auth secrets. |
| `upload_jobs` | Upload UUID, private R2 staging key, state, expected app, validator workflow/run ID, expiry, validation summary. |
| `rate_limit_buckets` | Short-lived keyed counters for admin login/API abuse controls; keyed by a keyed hash, not raw IP. |

Use foreign keys where supported, explicit SQL migrations, prepared statements, stable IDs, bounded text fields, and indexes for every public list/search path. Do not persist binaries or large screenshots in D1. Keep app DTOs separate from database row types.

## iOS client structure

Proposed deployment target: **iOS 16.0**. Gate MarketplaceKit behind its runtime and entitlement requirements. Use Swift, SwiftUI, async/await, Codable, URLSession, and system frameworks. The normal app UI is native; no WebView is used for catalog screens.

```text
App/                 App entry, dependency container, tab shell
Core/                shared configuration, identifiers, concurrency helpers
Networking/          APIClient, request/response envelopes, typed errors
Models/              StoreApp, AppVersion, Developer, Category, Screenshot
Services/            AppService, SearchService, UpdateService, DeviceCapabilityService
Repositories/        store API, repository validation, local metadata snapshots
Features/             Today, Apps, Search, Details, Updates, Library, Settings,
                      Sources, Onboarding
Components/           cards, image loader, skeleton, download control, galleries
Installation/         protocol, backend registry, OS-supported adapters, TrollStore handoff
Downloads/            background URLSession, task persistence, retry/cancel/cleanup
Security/             SHA-256, archive validation, source trust and URL policy
Persistence/          bounded catalog/download history and local preferences
Utilities/            semantic version comparison, formatting, accessibility/haptics
```

The current Xcode target is an iOS 16.0 SwiftUI app shell. Its five tab screens explicitly state that catalog features are not yet available; no sample app listing is bundled. The code has typed models, an API client, a repository contract, and a semantic-version utility. Download and package verification implementations are deferred to later phases.

The backend implements the read-only catalog API listed above. API response DTOs are in `shared/src/contracts.ts`; endpoint details are in [api.md](api.md). The admin page still performs a health check only and has no login or write controls until its later phase.

The tab shell is Today, Apps, Search, Updates, and Library. Features use lazy lists, task cancellation, Dynamic Type, VoiceOver labels, Reduce Motion, dark mode, explicit loading/empty/offline/error states, and no color-only status meaning.

## Repository contract

Repository v1 is specified in [repository-format.md](repository-format.md) and `shared/schemas/repository-v1.schema.json`. V1 uses strict unknown-field rejection, HTTPS URLs, bounded collections, UTC RFC 3339 dates, non-empty release lists, byte sizes, and lowercase 64-character SHA-256 digests. Shape validation is followed by semantic checks for duplicate bundle IDs and release pairs.

The app fetches third-party repositories directly from their HTTPS origin rather than making the backend proxy arbitrary user URLs. The add-source flow explains trust implications before the source is stored. Repository-provided descriptions and screenshots are untrusted display content.

## Licenses reviewed

The DreyzeStore source license is MIT. This license applies to DreyzeStore code, not to IPA files or media uploaded by repository maintainers; catalog releases require an explicit distribution-rights record from the publisher.

| Component | Upstream license / decision |
|---|---|
| TrollStore upstream | Its repository identifies most files as MIT and `RootHelper/uicache.m` as BSD-4-Clause. No TrollStore code is copied or linked. Preserve both notices and the CoolStar advertising acknowledgment if a future reviewed integration ever vendors that file. |
| TrollStore Lite | It is a build target in `opa334/TrollStore`, not a separately documented DreyzeStore SDK. It uses the shared TrollStore source with `TROLLSTORE_LITE`; it is not integrated. |
| Hono | MIT; direct API dependency in Phase 1. |
| React and Vite | MIT; direct admin dependencies in Phase 1. |
| Wrangler and `@cloudflare/workers-types` | MIT OR Apache-2.0; used for local Worker tooling and types. |
| Ajv and `ajv-formats` | MIT; used for strict shared repository-schema validation. |
| TypeScript | Apache-2.0; compiler and type checker. |
| ZIPFoundation | MIT; candidate for safe IPA ZIP inspection on iOS, subject to Phase 1 dependency review and tests against path traversal/size-limit behavior before use. |
| Cloudflare Workers, D1, R2 | Hosted services, not vendored libraries. Their plans/terms and quotas remain separate from the open-source code license. |

Upstream references: [TrollStore license](https://github.com/opa334/TrollStore/blob/main/LICENSE), [TrollStore Lite build target](https://github.com/opa334/TrollStore/blob/main/TrollStoreLite/Makefile), [Hono license](https://github.com/honojs/hono/blob/main/LICENSE), [React license](https://github.com/facebook/react/blob/main/LICENSE), [Vite license](https://github.com/vitejs/vite/blob/main/LICENSE), and [ZIPFoundation license](https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE).

## Phase gates

Phase 1 established the repository layout, project shells, shared schemas, local migrations, Worker health route, CI, and documentation. Phase 2 adds the public read-only API, D1 search/index constraints, repository generation, and fictional local-only metadata. Phase 3 will connect the iOS catalog UI. Admin management, package validation/download, installation, and production deployment remain later explicit phase gates. No production DNS, Cloudflare resources, or secrets have been created.
