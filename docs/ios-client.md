# iOS client

The native client targets iOS 16 and uses SwiftUI, async/await, and the public `/api/v1` catalog API. SwiftUI screens depend on view models; view models depend on `StoreRepository`; `NetworkStoreRepository` owns typed `APIClient` calls and bounded catalog snapshots.

## Development endpoint

Debug builds point to `http://127.0.0.1:8787/api/v1` for the local Wrangler Worker. Override the Xcode build setting `DREYZE_API_BASE_URL` for another development endpoint. The client accepts HTTPS endpoints generally and permits HTTP only for loopback in Debug. Release remains configured with the reserved `.invalid` host until a production endpoint is approved.

Run the API locally from the repository root:

```sh
npm run db:migrate:local
npm run db:seed:local
npm run dev:api
```

The development seed contains fictional metadata; it does not include or distribute IPA files. The placeholder asset URLs do not serve images, so the UI displays its built-in image placeholder for those records.

## Client behavior

- Today loads `/featured`, `/apps?sort=newest`, and `/apps?sort=updated`.
- Apps uses 24-item pages, category filters, and API-supported sorting.
- Search debounces requests by 350 ms and stores up to 10 recent terms on-device.
- Details load app metadata and published version history independently.
- Catalog JSON is cached for at most seven days, with an 8 MB total limit and 3 MB per entry. Failed network reads can use a still-valid snapshot; server and decoding failures do not fall back silently.
- Remote images use `URLCache` (24 MB memory / 96 MB disk), a 12 MB response limit, cancellable view tasks, and ImageIO thumbnails capped at 512 px for icons and 1,500 px for screenshots.
- Updates remains empty until a trustworthy installed-app inventory exists. The typed endpoint client is present but no inventory is fabricated or sent.
- GET opens a confirmation sheet, downloads the HTTPS release into a UUID-named managed temporary file, verifies SHA-256, inspects IPA structure and metadata, and retains only a verified package. The current client does not install or hand off packages.
- Library → Downloaded lists verified local packages and supports details/deletion. Settings → Storage displays package/cache/temporary usage and clears only DreyzeStore-managed files.
- Background transfers use a stable background URLSession identifier and UIApplicationDelegate restoration hooks. The OS controls scheduling; retry starts a fresh transfer.

## Tests

On macOS, run the app and XCTest target with:

```sh
xcodebuild test \
  -project ios/DreyzeStore/DreyzeStore.xcodeproj \
  -scheme DreyzeStore \
  -destination 'platform=iOS Simulator,name=<available iPhone>' \
  CODE_SIGNING_ALLOWED=NO
```

The GitHub Actions `iOS simulator build and tests` job runs the same scheme on a macOS simulator. Phase 4 adds generated ZIP fixtures for validator security cases and a local loopback HTTP integration test; an older run does not validate later changes.
