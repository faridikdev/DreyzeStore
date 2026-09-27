# Public API v1

Base path: `/api/v1`. All catalog endpoints are read-only. Unless noted, success responses use JSON `{ "data": ..., "meta": ... }`; JSON errors use `{ "error": { "code", "message", "requestId", "details?" } }`. `X-Request-Id` is also returned as a response header. A request ID is for support correlation, not authentication.

The catalog returns only published, non-deleted applications that have at least one published version. Draft apps/releases and internal database fields are not exposed. Text fields are untrusted display content. A matching package SHA-256 validates byte integrity against the published metadata; it does not prove that a package is safe.

## Endpoints

### `GET /apps`

Returns summaries, sorted by name by default.

Each summary includes `shortDescription`: whitespace-normalized app text capped at 160 Unicode code points. This keeps list cards self-contained and avoids one details request per visible row. The additive field can be ignored by existing clients.

```http
GET /api/v1/apps?category=utilities&repository=com.dreyze.official&sort=updated&page=1&limit=24
```

Supported filters: `category` (canonical slug such as `developer-tools`), `repository` (reverse-DNS identifier), and `sort` (`name`, `updated`, or `newest`). Pagination accepts `page` (1–1000) and `limit` (1–100). Alternatively, pass the returned opaque `cursor` with the same filters and sort; do not combine a cursor with `page`. Unknown or repeated query parameters are rejected.

```json
{
  "data": [
    {
      "id": "app-aurora-notes",
      "bundleIdentifier": "com.dreyze.auroranotes",
      "name": "Aurora Notes",
      "shortDescription": "Fictional sample note-taking app metadata for local catalog development.",
      "developer": { "id": "developer-dreyze-labs", "name": "Dreyze Labs (fictional)" },
      "category": { "id": "productivity", "name": "Productivity" },
      "iconURL": "https://cdn.example.invalid/icons/aurora-notes.png",
      "currentVersion": {
        "id": "version-aurora-1-1",
        "version": "1.1.0",
        "build": "2",
        "versionDate": "2026-09-22T11:36:49.029Z",
        "minimumOSVersion": "16.0",
        "downloadURL": "https://cdn.example.invalid/packages/aurora-notes/1.1.0/application.ipa",
        "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "size": 1287654,
        "releaseNotes": "Fictional development metadata only.",
        "channel": "stable"
      },
      "repositoryIdentifier": "com.dreyze.official",
      "repositoryName": "DreyzeStore Development"
    }
  ],
  "meta": { "page": 1, "pageSize": 24, "hasMore": false }
}
```

The example is fictional local-seed metadata. A next page includes `meta.nextCursor` when `meta.hasMore` is true. Cursor tokens are opaque and bound to the selected sort and filters; clients should pass them back unchanged.

### `GET /apps/{id}`

Returns full app details including developer, category, latest stable version (or the newest published version if there is no stable release), screenshots, and compatibility metadata in `currentVersion.minimumOSVersion`.

```http
GET /api/v1/apps/app-aurora-notes
```

```json
{
  "data": {
    "id": "app-aurora-notes",
    "bundleIdentifier": "com.dreyze.auroranotes",
    "name": "Aurora Notes",
    "developer": { "id": "developer-dreyze-labs", "name": "Dreyze Labs (fictional)", "websiteURL": "https://dreyzestore.invalid" },
    "category": { "id": "productivity", "name": "Productivity" },
    "iconURL": "https://cdn.example.invalid/icons/aurora-notes.png",
    "currentVersion": { "id": "version-aurora-1-1", "version": "1.1.0", "build": "2", "versionDate": "2026-09-22T11:36:49.029Z", "minimumOSVersion": "16.0", "downloadURL": "https://cdn.example.invalid/packages/aurora-notes/1.1.0/application.ipa", "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "size": 1287654, "releaseNotes": "Fictional development metadata only.", "channel": "stable" },
    "repositoryIdentifier": "com.dreyze.official",
    "repositoryName": "DreyzeStore Development",
    "description": "Fictional sample note-taking app metadata for local catalog development.",
    "screenshots": [{ "url": "https://cdn.example.invalid/screenshots/aurora-notes/overview.png", "width": 1179, "height": 2556, "alt": "Placeholder metadata for the fictional Aurora Notes app." }]
  }
}
```

Unknown or unpublished app IDs return `404`.

### `GET /apps/{id}/versions`

Returns only published releases for a published app, ordered newest publication timestamp first. Release objects include version, build, minimum iOS, published package URL, SHA-256, size, release notes, channel, and version date.

### `GET /categories`

Returns the canonical categories and counts of public apps in each category. Categories with no public apps remain in the response with `appCount: 0`.

### `GET /featured`

Returns configured Today sections in server order. Each section has `key`, `title`, and ordered `items`. Expired/future items and items whose app/release is not public are omitted.

### `GET /search?q=...`

Searches app name, developer, bundle identifier, description, and category using the D1 full-text index. It uses the same category/repository filters, sorting, and pagination as `/apps`. Query text must be at most 100 characters; up to 12 alphanumeric terms are searched as a prefix-AND query. An empty query returns an empty page. Search values are normalized into safe full-text tokens and passed through a bound SQL parameter.

```http
GET /api/v1/search?q=orbit&sort=name&limit=10
```

### `GET /updates?apps={JSON}`

Pass a URL-encoded JSON array with at most 25 unique installed app entries. Each item must contain exactly `bundleIdentifier` and `installedVersion`, both valid strings. The response includes only apps with a newer published **stable** release, determined using semantic version precedence.

```http
GET /api/v1/updates?apps=%5B%7B%22bundleIdentifier%22%3A%22com.dreyze.orbittimer%22%2C%22installedVersion%22%3A%221.9.0%22%7D%5D
```

```json
{
  "data": [
    {
      "app": { "id": "app-orbit-timer", "bundleIdentifier": "com.dreyze.orbittimer", "name": "Orbit Timer" },
      "installedVersion": "1.9.0",
      "latestVersion": { "version": "1.10.0", "build": "10", "minimumOSVersion": "16.0", "sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "size": 1000000, "channel": "stable" }
    }
  ]
}
```

The sample is abbreviated for readability; actual app and version objects use the shared DTOs. Duplicate bundle identifiers, malformed JSON, invalid versions, lists over 25 entries, or encoded request data over 2500 characters are rejected. Updates responses use `Cache-Control: no-store` because their URL contains installed-app inventory.

### `GET /repository`

Returns a repository-v1 JSON document generated from public apps and versions. The Worker validates the complete generated document with the shared JSON Schema and duplicate checks before responding. The document is not wrapped in an API envelope, so it can be consumed by any repository-v1 client. It never contains unpublished apps/releases or database object-key fields.

### `GET /health`

Returns `{ "data": { "status": "ok", "database": "ready" } }` when D1 responds. No database diagnostics are returned to clients.

## Errors and validation

| HTTP | Example code | Meaning |
| --- | --- | --- |
| `400` | `invalid_request` | Invalid, duplicate, or unsupported parameter |
| `404` | `not_found` | Unknown route or unpublished/missing app |
| `414` | `uri_too_long` | URL/query is too long |
| `413` | `request_too_large` | Oversized update list |
| `500` | `internal_error`, `catalog_data_invalid` | Unexpected error or invalid stored metadata |

Errors do not include SQL, stack traces, bucket keys, or D1 internals. Validation errors may include a field-to-message map. Responses include a request ID in the body and `X-Request-Id` header.

## Caching and CORS

Stable public catalog reads use `ETag` and bounded `Cache-Control` lifetimes and support `If-None-Match` (`304 Not Modified`). `/updates` is `no-store`. Errors are `no-store`. CORS only reflects exact origins listed in `ADMIN_ORIGINS`; it is not a wildcard. The local setting permits the Vite dev origin.

## Current limits

The local `.invalid` asset/package URLs are placeholders, so sample package links are intentionally not downloadable. This phase does not transfer bytes from R2, accept uploads, install apps, authenticate admins, or deploy Cloudflare resources. Those operations must be implemented in their later phases.
