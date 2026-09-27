# Continuous integration

`.github/workflows/ci.yml` has separate Windows Companion, backend/shared, admin, and iOS jobs. The Windows job runs Rust formatting/tests/check, builds the frontend and pinned `zsign` sidecar, produces unsigned MSI/NSIS installers, and uploads them as a short-lived workflow artifact. Linux jobs run ESLint, TypeScript, Vitest, SQLite migration validation, Wrangler `--dry-run`, and the Vite build. The macOS job resolves Xcode package dependencies, selects an available iPhone simulator, and runs `xcodebuild test` with signing disabled.

Every hosted job has a public-repository guard. The public repository at `github.com/faridikdev/DreyzeStore` runs the hosted jobs on push and pull requests. This project does not create Cloudflare resources or use paid services as part of CI.

The local Windows workspace runs the Node, migration, Worker dry-run, Vite, Rust tests, and (with Visual Studio C++ tools) unsigned MSI/NSIS bundle checks. `xcodebuild` is available only on the macOS GitHub runner; the iOS result must be taken from a workflow run for the exact commit being reviewed. CI/device mocks do not verify installation on a physical iPhone.
