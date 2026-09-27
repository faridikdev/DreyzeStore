# Initial administrator bootstrap

The repository has no default account or password. `scripts/bootstrap-admin.mjs` creates one administrator with a cryptographically random, one-time password and stores only a salted Argon2id hash. It cannot run without an explicit `--local` or `--remote` target.

## Local development

First create the local D1 schema:

```sh
npm run db:migrate:local
npm run admin:bootstrap:local -- --email=you@example.test
```

The command prints the generated password once after D1 confirms that the account was inserted. Save it in a password manager; the plaintext is not written to a file or command-line argument. Start the API and Admin panel afterwards. Local cookies are not Secure because local HTTP is used.

## Later remote bootstrap

This documents a future operator action only; it has **not** been run for DreyzeStore. After production D1 exists and has reviewed migrations applied, an operator may target the exact database name:

```sh
node scripts/bootstrap-admin.mjs --remote --database=<exact-d1-database-name> --email=you@example.test
```

The script asks the operator to type that exact database name before it invokes Wrangler. It refuses if an enabled password-based administrator already exists, has no `--password` option, writes a temporary SQL file under the current user's temp directory, and removes it in a `finally` block. The generated password exists in process memory until it is printed. Run only from a trusted workstation with Wrangler already authenticated to the intended account; check the selected Cloudflare account and database before confirming.

The CLI does not create D1/R2, set Worker secrets, deploy code, or change DNS. Do not add the generated password to shell history, issue trackers, logs, or Git. If the password is lost, there is no self-service reset flow in this phase; use a reviewed, operator-controlled credential reset procedure and revoke existing sessions.

## KDF and stored fields

Credentials use `argon2id-v1`, 19,456 KiB memory, two passes, parallelism one, a random 32-byte salt and a 32-byte hash. D1 has checks for algorithm parameters, salt/hash encoding and iteration bounds. Migration 0004 preserves prior bounded PBKDF2 rows and converts them after a successful login. See [the KDF ADR](adr/0003-admin-password-kdf.md) and [security model](security.md).
