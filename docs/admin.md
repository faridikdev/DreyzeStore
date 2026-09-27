# DreyzeStore Admin

The Admin app is a React/TypeScript/Vite single-page interface at `admin/`. It is a client of the versioned API and does not connect to D1/R2 directly. It has login, dashboard counts/activity/storage, app list/search, app drafts, metadata editing, icon/screenshots upload/reorder/remove, release review, featured ordering, and explicit publish/reject/unpublish/delete confirmations.

## Local setup

```powershell
Copy-Item admin/.env.example admin/.env.local
npm run dev:admin
```

Set `VITE_API_BASE_URL` to the API `/api/v1` origin. For local development use `http://localhost:8787/api/v1`. Vite variables are public client configuration, never secret values. The API must allow the exact Admin origin in `ADMIN_ORIGINS`.

Apply local D1 migrations and create the first password account with [admin bootstrap](admin-bootstrap.md). Local upload endpoints require `LOCAL_UPLOADS_ENABLED=true` in `backend/.dev.vars`; they are development-only. Production storage uses direct short-lived signed R2 URLs and the isolated validator workflow.

## Roles and write confirmation

`admin` and `editor` can work on app metadata and release review. Only `admin` can publish, reject, unpublish or delete. This is enforced by API middleware. A publish requires the Admin UI rights checkbox and a second confirmation; the server independently requires `confirmRights: true`, a ready-for-review upload, validated IPA metadata matching the app, package checksum/size and a unique version/build. Destructive actions require an explicit confirmation.

The client stores the CSRF token only in page memory. It sends it in `X-CSRF-Token`, and relies on the HttpOnly session cookie. It does not persist an auth bearer token in localStorage. Refreshing the page asks the API for the authenticated session and a fresh CSRF token.

## App and release workflow

1. Create an app draft with name, reverse-DNS bundle ID, developer, existing category/source, description and short description.
2. Upload a PNG/JPEG icon and optional screenshots. The server verifies image structure/size/dimensions before moving bytes into public assets.
3. Start an IPA upload; the server creates an opaque upload ID and private key. The browser uploads bytes directly to staging, not through the ordinary Worker request body.
4. Complete the upload. The Worker checks staged object presence and exact size, then dispatches the protected validation workflow.
5. Review the detected bundle ID, version/build, minimum OS, size and server-computed SHA-256. A mismatch blocks publish and cannot be overridden from the Admin UI.
6. Add release notes/channel. An admin confirms distribution rights, then publishes. Only the public R2 copy and D1 release transition make it visible in catalog/search/featured/repository.

Detailed transition/transaction behavior is documented in [upload-pipeline.md](upload-pipeline.md). Admin and callback paths are listed in [api.md](api.md).

## Data handling

All Admin reads use `Cache-Control: no-store`. Errors include a request ID but no stack trace or SQL. Audit activity is a bounded, pseudonymous view; it contains neither credentials nor raw upload bytes. The UI never labels a release malware-safe. A checksum verifies bytes against the published digest only.

## Current operational limits

There is no Admin user-management/password-reset screen, scheduled cleanup/retention job, image re-encoder, production Cloudflare configuration, or deployment. Local testing uses generated package fixtures and does not require authorized third-party IPA files.
