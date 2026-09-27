# Backend development

The public API is a TypeScript Cloudflare Worker using Hono. Routes call catalog services; services validate stored data and map public DTOs; repositories own all D1 SQL. D1 stores catalog metadata. R2 bindings are configured for future public assets and private staging, but this phase does not upload, retrieve, or stream package bytes.

## Local commands

From the repository root:

```sh
npm ci
npm run db:migrate:local
npm run db:seed:local
npm run dev:api
```

Wrangler serves `http://localhost:8787`. The development seed contains only fictional metadata and `.invalid` asset/package URLs; it does not contain IPA files or create R2 objects. The seed is intended for the local database only.

`GET /api/v1/health` checks the local D1 binding. The public catalog endpoints and their contracts are documented in [api.md](api.md). Do not add `--remote` to local commands. The default build is a Worker dry-run and does not deploy or provision resources.

## API and data layers

The API is versioned under `/api/v1/`. Routes validate query and path inputs and return a common `{ "error": { "code", "message", "requestId" } }` shape for failures. Public success responses use `{ "data": ..., "meta": ... }`, except `/repository`, which is the repository-v1 document itself. Catalog reads only include published, non-deleted apps with at least one published release. Release and asset metadata is validated before it leaves the Worker.

`backend/src/routes/` contains HTTP handlers, `services/` owns public DTO construction and domain rules, `repositories/` owns D1 queries, and `db/` contains binding utilities. Prepared statements are used for data values; sorting clauses are selected from fixed allowlists. Pagination is bounded to 100 items and page numbers to 1000. Search uses the local D1 FTS5 index and tokenized, bound query expressions.

The repository response is generated from published rows and validated with the shared JSON Schema v1 validator before it is returned. It exposes public HTTPS URLs derived from asset references, not D1 columns such as `ipa_object_key` or admin/audit data.

## D1 and R2

`backend/migrations/` contains ordered SQL migrations. `0001_initial_schema.sql` is preserved; `0002_public_catalog.sql` adds public-catalog indexes, bounded publication constraints, and the FTS5 index/triggers. `python scripts/validate_migrations.py` executes the migrations against SQLite, checks indexes/foreign keys and constraints, then verifies the seed and search index.

The checked-in Wrangler configuration is local-development configuration. Its D1 identifier is a placeholder and R2 bucket names configure only local bindings; no production D1/R2 resources, DNS, or secrets are created. `PUBLIC_ASSETS_BASE_URL` must be an HTTPS public asset host in a future deployment. Package object keys are only metadata references at this stage; downloads and package validation are later phases.

Admin authentication, upload authorization, package parsing, publication workflows, and retention jobs are not implemented in this phase. The local SQL seed is not an admin API and must not be run against production.
