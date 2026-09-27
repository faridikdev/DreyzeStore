# DreyzeStore

[English](README.md) · [Русский](README.ru.md)

DreyzeStore is an open-source project for a native iOS app catalog, package metadata API, repository format, and web administration panel. It is being built in phases. **Phase 2 implements the public read-only catalog API and local development seed; the full store is not complete:** admin login and editing, package upload/download, IPA validation, real installation adapters, and production deployment have not been implemented.

An ordinary sandboxed iOS app cannot generally install an arbitrary IPA or enumerate every installed app. The client will only report an installation when a real, available backend confirms it. Downloading or verifying a package is a separate state.

## Architecture

- `ios/DreyzeStore`: SwiftUI iOS app, minimum iOS 16.0, async `URLSession` API client, typed models, and a capability-gated installation protocol.
- `backend`: TypeScript Cloudflare Worker using Hono, local D1 migrations, and local R2 bindings for eventual public assets and private staging.
- `admin`: React, TypeScript, and Vite static administration client. Phase 1 performs an API health check; write workflows and authentication are deferred.
- `shared`: repository JSON Schema v1 and shared API DTOs.
- `.github/workflows/ci.yml`: Linux backend/admin checks and macOS simulator build/test.

See [architecture](docs/architecture.md), [backend development](docs/backend.md), [API reference](docs/api.md), [repository format](docs/repository-format.md), [installation boundary](docs/installation.md), [security](docs/security.md), [licenses](docs/licenses.md), [CI boundary](docs/ci.md), and [deployment boundary](docs/deployment.md).

## Screenshots

Screenshots will be added after the native catalog screens are implemented. The current iOS views explicitly identify themselves as not yet connected to store content.

## Requirements

- Node.js 22.12+ and npm.
- Python 3 for the local D1 migration check.
- macOS and Xcode for iOS builds and XCTest.
- No Cloudflare account is needed for local API development. No production resources are created by this repository's setup or CI.

## Building the iOS client

Open `ios/DreyzeStore/DreyzeStore.xcodeproj` in Xcode, or run on macOS:

```sh
xcodebuild test \
  -project ios/DreyzeStore/DreyzeStore.xcodeproj \
  -scheme DreyzeStore \
  -destination 'platform=iOS Simulator,name=<available iPhone>' \
  CODE_SIGNING_ALLOWED=NO
```

The configured API URL ends in the reserved `.invalid` domain until a future environment config supplies an endpoint. No demo catalog is compiled into the app.

## Running the backend

```sh
npm ci
npm run db:migrate:local
npm run db:seed:local
npm run dev:api
```

The Worker serves the public catalog API under `/api/v1/`, including app listing/details/versions, categories, featured sections, search, updates, repository-v1 generation, and health. API requests and response examples are in [docs/api.md](docs/api.md). The local seed contains fictional metadata and placeholder `.invalid` asset URLs only; no IPA files are included. Wrangler uses local D1 and R2 emulation. With the Worker running, `npm run smoke:api:local` exercises it against local D1 and validates the repository response. Do not pass remote flags during local development.

## Running the admin panel

In another terminal:

```powershell
Copy-Item admin/.env.example admin/.env.local
npm run dev:admin
```

The panel checks the configured API. It does not show fictional app entries, accept credentials, or offer nonfunctional editing controls. Authentication and management arrive in a later phase.

## Cloudflare setup

`backend/wrangler.jsonc` contains a placeholder D1 ID and local bucket names. These names configure Wrangler's local bindings; they do not create cloud resources. Production D1/R2, domains, DNS, and secrets are deliberately not configured. Review [deployment.md](docs/deployment.md) and obtain explicit approval before any future paid or production action.

## Repository format

Repository v1 is JSON Schema Draft 2020-12 at [shared/schemas/repository-v1.schema.json](shared/schemas/repository-v1.schema.json). It strictly validates HTTPS URLs without credentials, UTC timestamps, reverse-DNS identifiers, version/build, minimum OS, screenshot metadata, package size, and lowercase SHA-256. The same runtime validator adds duplicate identifier checks. Test metadata lives only in the test suite and is not served as a catalog.

## Installation backends

The app defines `InstallationBackend` only. There are no TrollStore, TrollStore Lite, signing, marketplace, or external installer adapters yet; no exploit code is included. See [installation.md](docs/installation.md) for the current status and platform constraints.

## Security

See [SECURITY.md](SECURITY.md) and [docs/security.md](docs/security.md). Never commit credentials, `.env` files, IPA/TIPA packages, signing keys, or production configuration. A matching checksum establishes integrity against a repository's published digest, not that an app or publisher is safe.

## Licenses

DreyzeStore source code is licensed under MIT. Repository content, screenshots, and application packages require their own distribution rights; the project license grants no rights to them. Direct third-party dependency licenses reviewed for Phase 1 are listed in [docs/licenses.md](docs/licenses.md).

## Contributing

Use the documented phases and keep each change reviewable. Run `npm run check`, validate migrations, and run the Xcode test scheme on macOS for iOS changes. Do not claim unfinished routes or installation behavior as complete. See [developer workflow](docs/developer-workflow.md).
