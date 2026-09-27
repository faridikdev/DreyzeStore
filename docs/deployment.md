# Deployment boundaries

Phase 1 does not deploy DreyzeStore, create a Cloudflare account or resource, change DNS, add a domain, or set secrets. `backend/wrangler.jsonc` is a local Worker configuration with a placeholder D1 identifier and local-only R2 bucket names. The admin static build is an artifact only; it is not uploaded anywhere.

## Before a future deployment

1. Choose and verify the repository's public/private visibility. The Phase 0 package-validation design assumes public-repository GitHub Actions standard runners to avoid relying on paid runner allowance.
2. Create Cloudflare resources manually only after reviewing current free-tier limits and receiving explicit authorization for any potentially chargeable use.
3. Set production D1 IDs, R2 names, custom domains, and non-secret origins in an environment-specific configuration that is not committed.
4. Enter secrets using the provider's secret store; never add them to source, workflow YAML, client bundles, or ordinary variables.
5. Apply migrations against a reviewed target. Do not run destructive production migration or deletion commands without explicit approval.
6. Deploy the Worker and admin only after authentication, authorization, rate limiting, package-validation, audit, and operational checks are implemented.

There are no production deployment commands in Phase 1 CI. The Worker build uses Wrangler's `--dry-run` bundler only.
