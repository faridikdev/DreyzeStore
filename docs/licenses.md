# Licenses

The DreyzeStore source is distributed under the root MIT license. That license does not grant rights to upload, host, modify, or redistribute third-party applications, screenshots, icons, or repository content. A release must have the publisher's authorization recorded before publication.

No TrollStore or TrollStore Lite source or binary is included in this repository. Phase 0 research used official upstream sources and is documented in the architecture and installation decision records. A future integration requires a separate license and source review; upstream notices must be preserved.

## Direct dependencies

License identifiers below are from the resolved package metadata/notice files installed from the checked-in npm lockfile. Transitive packages retain their own terms and notices.

| Component | Purpose | License |
|---|---|---|
| Hono | Worker HTTP routing | MIT |
| argon2id 1.0.1 | Argon2id password KDF (prebuilt upstream Wasm) | MIT |
| Ajv, ajv-formats | JSON Schema validation | MIT |
| React, React DOM, Vite, `@vitejs/plugin-react` | Admin web application | MIT |
| Wrangler | Local Worker tooling and dry-run bundling | MIT OR Apache-2.0 |
| `@cloudflare/workers-types` | Worker TypeScript bindings | MIT OR Apache-2.0 |
| TypeScript | Type checking | Apache-2.0 |
| ESLint, typescript-eslint, Vitest, jsdom | Linting and tests | MIT |
| `@types/node`, `@types/react`, `@types/react-dom`, `globals`, `@eslint/js` | Type/tooling support | MIT |
| ZIPFoundation 0.9.20 | Bounded ZIP entry inspection for IPA metadata | MIT |

The ZIPFoundation package is pinned in `ios/DreyzeStore/DreyzeStore.xcodeproj/project.pbxproj`; its upstream notice is reproduced in [`docs/third-party/ZIPFoundation-MIT.txt`](third-party/ZIPFoundation-MIT.txt). No ZIPFoundation source code is vendored. The GitHub Actions workflow pins official GitHub-maintained actions to commit SHAs; review their upstream license notices when changing those pins.

`argon2id` is an npm runtime dependency from [openpgpjs/argon2id](https://github.com/openpgpjs/argon2id). Its MIT copyright and permission notice (including Proton AG and Emil Bay attribution) is reproduced in [`docs/third-party/argon2id-MIT.txt`](third-party/argon2id-MIT.txt). Only the published dependency package is used; DreyzeStore does not copy or modify its implementation source.

For the exact resolved dependency graph, consult `package-lock.json` and each package's included license/notice file.
