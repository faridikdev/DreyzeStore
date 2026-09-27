# Backend development

The API is a Cloudflare Worker written in TypeScript with Hono. It uses D1 for relational metadata and separate R2 bindings for public assets and private upload staging. The checked-in Wrangler configuration is local-development configuration only: its D1 identifier is a local placeholder, and bucket names are not provisioned by this repository.

## Local commands

From the repository root:

```sh
npm install
npm run db:migrate:local
npm run dev:api
```

The local Worker listens on `http://localhost:8787`. The only implemented endpoint in this foundation is `GET /api/v1/health`; it returns ready only when the D1 binding can answer a query. Store and admin endpoints are intentionally not represented as working routes yet.

To create the local D1 database before migrations, run:

```sh
npm run db:create:local
npm run db:migrate:local
```

`db:create:local` only initializes Wrangler's local state. Do not add `--remote` to local development commands. No command in the normal build or CI workflow provisions cloud resources or performs a deployment.

## API contract baseline

Shared TypeScript DTOs live in `shared/src/contracts.ts`. The public response envelope is `{ "data": ..., "meta": ... }`, and errors use `{ "error": { "code", "message", "requestId" } }`. Unimplemented endpoints return `404`; this prevents callers from mistaking planned routes for functioning services. The normative repository response is defined by `shared/schemas/repository-v1.schema.json`.

## D1 and R2

`backend/migrations/` contains ordered SQL migrations. Apply them locally with Wrangler. Package bytes and image objects are represented by R2 object keys in metadata, never stored in D1 or Git. The local `PUBLIC_ASSETS` and `STAGING_ASSETS` bindings are isolated from production and remote buckets.

Admin authentication, upload authorization, package parsing, publication, and retention jobs are not implemented in this foundation. They must be completed before any admin endpoint can mutate data or any public release is served.
