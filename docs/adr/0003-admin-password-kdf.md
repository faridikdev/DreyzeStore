# ADR 0003: Run Argon2id password verification in a Durable Object

- **Status:** Accepted for Phase 6
- **Date:** 2026-09-27

## Context

Admin sign-in needs a modern memory-hard password hash suitable for a Cloudflare Workers runtime. The initial foundation used PBKDF2-HMAC-SHA256 at 600,000 iterations. In the production Workers runtime, the WebCrypto PBKDF2 derive path rejects counts above its current runtime cap; local `wrangler dev` did not reveal this. Keeping that implementation would make production logins fail.

## Decision

Use the MIT-licensed `argon2id` upstream WebAssembly implementation (`openpgpjs/argon2id`) with Argon2id v1 parameters `m=19,456 KiB`, `t=2`, `p=1`, 32-byte random salts and 32-byte output. Bundle the package's SIMD/non-SIMD Wasm modules statically, instantiate them through the Cloudflare-supported compiled-Wasm module path, and run hashing only in an internal `AdminPasswordKdf` Durable Object. The Worker accesses that object through a binding; no user-controlled route exposes it. Login requests are rate-limited before KDF work. New bootstrap accounts use Argon2id. The 0004 migration preserves earlier bounded PBKDF2 rows and successfully authenticated legacy accounts are upgraded to Argon2id.

## Consequences

- Password work is isolated from the public catalog Worker request's normal CPU budget and uses the Durable Object CPU limit. DO request quotas and memory/latency must be tested on the selected plan before deployment.
- A DO namespace binding/class migration is required; local/dry-run builds can validate packaging but do not prove a production account's plan quotas or latency.
- Password values are sent only through the Worker's internal binding to the KDF object and are never stored/logged. The KDF object returns only `{ verified, upgraded? }`.
- The Argon2id package's complete upstream license notices must remain acknowledged in the repository's license documentation.
- Existing PBKDF2 password records incur a one-time manual HMAC verification and then receive a new Argon2id hash on successful login. New accounts never create PBKDF2 records.

## Alternatives considered

- **PBKDF2 in Workers WebCrypto:** rejected because the necessary iteration count exceeds the production runtime cap.
- **Low-iteration PBKDF2:** rejected because lowering work to fit the Worker CPU quota would weaken stored-password resistance.
- **External password service:** rejected because it adds credentials, network dependencies, operational cost and a second trust boundary.
- **Run KDF in every Worker request:** rejected because the normal Workers CPU budget is not appropriate for memory-hard hashing; the isolated DO has a documented independent invocation budget.

## References

- Cloudflare [WebAssembly modules in JavaScript Workers](https://developers.cloudflare.com/workers/runtime-apis/webassembly/javascript/)
- Cloudflare [Durable Objects limits](https://developers.cloudflare.com/durable-objects/platform/limits/) and [pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- Cloudflare workerd [PBKDF2 iteration limit issue](https://github.com/cloudflare/workerd/issues/1346)
- `argon2id` upstream source and license: <https://github.com/openpgpjs/argon2id>
