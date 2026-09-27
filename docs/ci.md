# Continuous integration

`.github/workflows/ci.yml` has separate backend/shared, admin, and iOS jobs. Linux jobs run ESLint, TypeScript, Vitest, SQLite migration validation, Wrangler `--dry-run`, and the Vite build. The macOS job resolves Xcode package dependencies, selects an available iPhone simulator, and runs `xcodebuild test` with signing disabled.

Every hosted job has a public-repository guard. The public repository at `github.com/faridikdev/DreyzeStore` runs the hosted jobs on push and pull requests. This project does not create Cloudflare resources or use paid services as part of CI.

The local Windows workspace runs the Node, migration, Worker dry-run, and Vite checks. `xcodebuild` is available only on the macOS GitHub runner; the iOS result must be taken from a workflow run for the exact commit being reviewed.
