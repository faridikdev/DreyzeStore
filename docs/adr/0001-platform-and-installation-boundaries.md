# ADR 0001: platform, package pipeline, and installation boundaries

- **Status:** Accepted for Phase 1 planning; no deployment or external account changes authorized.
- **Date:** 2026-09-27
- **Scope:** Initial DreyzeStore V1 monorepo architecture.

## Context

The requested product spans a native iOS app, REST API, public and third-party repositories, large IPA files, a web admin, release validation, updates, and several installation environments. An ordinary iOS app can download and inspect files but cannot assume a universal IPA installation API or installed-app inventory. Installation backends also have different OS, entitlement, region, and environment requirements.

The workspace `C:\Users\pc\DreyzeStore` was inspected and contains no files and no `.git` repository. There was no existing code, manifest, history, or license to preserve. Phase 0 therefore defines the initial architecture from the provided brief and upstream documentation; it does not infer existing product behavior.

## Decisions

### 1. Keep the requested Cloudflare control plane

Use TypeScript, Hono, Cloudflare Workers, D1 for metadata, and R2 for packages/assets. This aligns with the requested inexpensive deployment shape and keeps large objects out of SQL. Keep local Wrangler configuration possible without a Cloudflare account.

### 2. Put archive-heavy validation in an isolated GitHub Actions job

The Worker handles authorization, state transitions, short-lived upload capabilities, D1, and R2 promotion. An ephemeral standard Ubuntu runner processes pending packages. Current Workers Free limits are 10 ms CPU per HTTP request and 100 MB inbound body size; R2 supports direct object uploads/presigned operations. Free hosted standard runners are available for public repositories. This avoids treating a constrained edge request as an IPA parser and avoids making Workers Paid a baseline requirement.

The free-runner assumption depends on a public open-source repository, standard runner types, minimal retained workflow artifacts, and staying inside the R2 free allowance. If any assumption fails, uploads pause until a zero-cost alternative is selected or the user explicitly approves a paid action. No cost is incurred by this architecture decision itself.

### 3. Use a static React/Vite admin frontend with API-owned security

Admin pages need authenticated CRUD and upload progress, not search indexing or server-side rendering. Use React + TypeScript + Vite as a static SPA; Hono owns OAuth, secure sessions, CSRF, authorization, validation, and data. This removes a second production server from the stack. Host it at `admin.<domain>` and allow only that origin from the API.

### 4. Use a native SwiftUI iOS client and a small modular deployment target

Use SwiftUI, async/await, Codable, URLSession, and typed services with feature-level views. Proposed minimum OS is iOS 16.0. Keep marketplace-only APIs behind the actual OS and entitlement checks. Persist a bounded offline catalog snapshot and download history; never embed production demo listings.

### 5. Make validation a prerequisite for installation and publication

The admin upload has a staging state machine. A server-side isolated validator computes SHA-256 and reads IPA metadata from a ZIP without running package contents. Admin reviews extracted metadata before publish. The iOS client independently recomputes SHA-256 and checks archive/bundle metadata before creating a verified-package value. No mismatch can reach an installer.

### 6. Treat installation as a capability and report external handoff separately

Adopt a protocol-based `InstallationBackend` registry, but `install` returns either an authoritative installed result or an external/system handoff. Only backend-confirmed results become `Installed`. No backend is considered available solely because it is present in the source tree.

Do not embed TrollStore/TrollStore Lite code. TrollStore is an exploit-dependent external tool with a narrow upstream support list. Its URL scheme collides with the system Magnifier scheme and is not a reliable detection probe. TrollStore Lite is built from shared upstream source with private frameworks and a jailbreak-root `ldid` dependency; it is not a general DreyzeStore SDK.

### 7. Define one strict versioned repository contract

Repository documents use schema version 1 and JSON Schema Draft 2020-12. The client bundles its validator schema and validates source data before display. App releases include HTTPS URL, exact byte size, minimum OS, build/version, and SHA-256. The machine schema is placed at `shared/schemas/repository-v1.schema.json` in Phase 1, with a normative explanation in `docs/repository-format.md`.

### 8. Use MIT for DreyzeStore code and keep package rights separate

Propose MIT for DreyzeStore source code. Every distributed package and asset must have separately recorded distribution rights; the repository license does not grant rights to third-party IPAs. No TrollStore source is copied. Future third-party notices are generated from the locked dependency graph.

## Alternatives considered

| Alternative | Decision |
|---|---|
| Compute SHA and parse arbitrary IPA fully in a Free Worker | Rejected as the baseline: 10 ms active CPU is not a dependable budget for full-file hash and archive parsing. |
| Put IPA files in D1 or Git | Rejected: D1 is metadata storage, and package binaries do not belong in source history. |
| Require a Workers Paid plan | Rejected as the default: current plan has a $5/month minimum and the user's instruction prefers free tiers. Can be reconsidered only with approval. |
| Next.js admin runtime | Not selected: server rendering/runtime are unnecessary for the authenticated admin workflow; static React/Vite has fewer hosted components. |
| In-app direct TrollStore installation as an ordinary backend | Rejected: upstream documents an external scheme handoff, not a general public API or reliable success callback; OS support is exploit-dependent. |
| Report Installed after opening a URL or finishing download | Rejected: neither proves OS installation. |
| iOS-wide installed-app scan for updates | Rejected: not available to an ordinary sandboxed app through a general public API. Use known backend/user-reported inventory only. |
| Add an Apple MarketplaceKit adapter immediately | Deferred: its entitlement, region, eligibility, and notarized package requirements are not available to a generic client by default. |

## Consequences

### Positive

- Metadata and binary storage have clear ownership and separate failure/scaling paths.
- The mobile UI can truthfully distinguish download, verification, install handoff, and completed installation.
- The app remains useful offline and on devices without an installer.
- Cost-sensitive local development and public-repository CI are possible without production infrastructure.
- Repository metadata is shared and validated at defined boundaries.

### Risks and follow-up

- A general consumer IPA installation flow is not achievable on stock devices without a valid system-authorized distribution path. This may constrain App Store distribution and install actions.
- Apple's marketplace entitlement/eligibility is a separate product and business gate, not a coding task.
- TrollStore's upstream OS matrix can change and is intentionally not broadened by DreyzeStore.
- GitHub Actions validation introduces an asynchronous dependency and assumes a public repository; UI must expose pending/failed validation states.
- R2 free allowance is finite; large packages can exhaust storage allowance even though egress is free.
- SHA-256 alone does not authenticate the publisher. Signed catalog metadata and a key rotation design are required before making stronger provenance claims.
- Third-party repository URLs and metadata are untrusted; first-party validation does not certify package safety.
- The repository has no chosen remote visibility, owner/domain, or deployment account; those are not set in Phase 0.

## Upstream and platform sources

- [TrollStore upstream README](https://github.com/opa334/TrollStore/blob/main/README.md)
- [TrollStore upstream license](https://github.com/opa334/TrollStore/blob/main/LICENSE)
- [TrollStore Lite Makefile](https://github.com/opa334/TrollStore/blob/main/TrollStoreLite/Makefile)
- [TrollStore upstream root helper](https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m)
- [Apple alternative marketplace overview](https://developer.apple.com/support/alternative-app-marketplace-in-the-eu/)
- [Apple MarketplaceKit: creating a marketplace](https://developer.apple.com/documentation/marketplacekit/creating-an-alternative-app-marketplace)
- [Cloudflare Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
- [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/)
- [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [GitHub Actions OIDC](https://docs.github.com/en/actions/reference/security/oidc)

## Phase 1 scope boundary

After explicit authorization, Phase 1 may create the monorepo/project shells, repository schema file, migrations skeleton, CI, and foundation documentation. It must not provision production Cloudflare resources, change DNS, purchase a domain, configure production secrets, or move to the backend feature phase.
