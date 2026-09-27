# Developer workflow

## Prerequisites

- Node.js 22.12 or later and npm.
- Python 3 for applying D1 migration checks using SQLite's standard library.
- macOS with Xcode for building and testing the iOS target.
- Cloudflare account access is not required for local development and is not used by Phase 1 CI.

## First run

```sh
npm ci
npm run db:migrate:local
```

In separate terminals, start the API and admin:

```sh
npm run dev:api
npm run dev:admin
```

Copy `admin/.env.example` to `admin/.env.local` if a local API base URL needs to be configured. The copied file is ignored by Git. The admin page reports real API/database health; it does not contain app or release sample data.

## Checks

```sh
npm run check
```

This runs ESLint, TypeScript checks, Vitest suites, an in-memory SQLite application of every D1 migration, and dry-run Worker/admin builds. The iOS project and XCTest suite run separately on macOS:

```sh
xcodebuild test \
  -project ios/DreyzeStore/DreyzeStore.xcodeproj \
  -scheme DreyzeStore \
  -destination 'platform=iOS Simulator,name=<available iPhone>' \
  CODE_SIGNING_ALLOWED=NO
```

The GitHub Actions workflow currently runs hosted jobs only when the repository is public, avoiding possible billing for a private repository with exhausted included minutes. See [CI boundaries](ci.md).

Never put `.env` files, Cloudflare credentials, Apple signing material, IPA/TIPA packages, or build output in Git. Review `git status --short` and `git diff --check` before committing.
