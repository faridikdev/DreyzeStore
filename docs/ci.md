# Continuous integration

`.github/workflows/ci.yml` has separate backend/shared, admin, and iOS jobs. Linux jobs run ESLint, TypeScript, Vitest, SQLite migration validation, Wrangler `--dry-run`, and the Vite build. The macOS job resolves Xcode package dependencies, selects an available iPhone simulator, and runs `xcodebuild test` with signing disabled.

Every hosted job has a public-repository guard. GitHub documents standard hosted runners as free and unlimited for public repositories; private repositories instead consume account minutes and may be charged after the allowance. With repository visibility not yet chosen, the workflow skips all hosted jobs for a private repository to prevent an unexpected paid run. The workflow can be enabled for a private repository only after its owner has reviewed the applicable GitHub allowance/cost and explicitly authorized that use.

The current local workspace has no GitHub remote, so hosted jobs cannot be dispatched from this checkout. All Node, migration, Worker dry-run, and Vite checks are run locally; `xcodebuild` is available only on a macOS runner.
