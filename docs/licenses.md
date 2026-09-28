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
| `isideload` 0.4.0 | Experimental Windows Apple Account/provisioning protocol client | MIT |
| `isideload-apple-codesign` 0.29.11 | Local app code-signing dependency | MPL-2.0 |
| `apple-codesign-quick` 0.1.0 | Transitive signing/profile parser | LGPL-2.1-or-later |

The ZIPFoundation package is pinned in `ios/DreyzeStore/DreyzeStore.xcodeproj/project.pbxproj`; its upstream notice is reproduced in [`docs/third-party/ZIPFoundation-MIT.txt`](third-party/ZIPFoundation-MIT.txt). No ZIPFoundation source code is vendored. The GitHub Actions workflow pins official GitHub-maintained actions to commit SHAs; review their upstream license notices when changing those pins.

`argon2id` is an npm runtime dependency from [openpgpjs/argon2id](https://github.com/openpgpjs/argon2id). Its MIT copyright and permission notice (including Proton AG and Emil Bay attribution) is reproduced in [`docs/third-party/argon2id-MIT.txt`](third-party/argon2id-MIT.txt). Only the published dependency package is used; DreyzeStore does not copy or modify its implementation source.

For the exact resolved dependency graph, consult `package-lock.json` and each package's included license/notice file.

The Windows Companion pins `isideload` to commit `52b504c2cd706a9e415109b0be9e137168034f5e` and `isideload-apple-codesign` to commit `3100109c6a967375dec78f018be5f4a42cd1bdd9`; their notices are included under `apps/windows-companion/src-tauri/licenses/`. `apple-codesign-quick` is LGPL-2.1-or-later and is linked into the Rust binary. Any binary distribution must provide the required source/relinking materials and pass a release-specific LGPL compliance review. No Apple-signing source code from SideStore or iLoader is copied into DreyzeStore.
