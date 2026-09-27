# IPA upload and release publishing pipeline

```text
Admin session + CSRF
  → private staging upload session
  → direct HTTPS R2 PUT
  → exact-size completion + one-run validation dispatch
  → isolated GitHub runner reads this one object
  → OIDC-authenticated report
  → metadata review + distribution-rights attestation
  → immutable public R2 copy + transactional D1 publish
  → public API/repository + iOS client verification
```

## State transitions

`upload_jobs.state` is constrained in D1. Normal states are:

| State | Meaning |
|---|---|
| `created` / `uploading` | Upload session exists; private bytes are not yet accepted as complete |
| `uploaded` | Exact staged object is present |
| `queued` | A one-use validator ticket has been created or workflow dispatch is retryable |
| `validating` | A verified GitHub workflow run owns the nonce-bound lease |
| `validation_failed` | Trusted validator rejected the structure or metadata; cannot publish |
| `ready_for_review` | Trusted validation passed and app bundle/size matched |
| `publishing` | Server is copying the validated object into its immutable distribution key |
| `published` | D1 release, rights record, public app state and audit transition committed |
| `rejected` / `expired` | No public package; private staging bytes are eligible for removal |

Conditional D1 updates prevent duplicate claims/publishes. If publication cannot commit after the public copy is written, the copy is removed and the job is reset to `ready_for_review`. The D1 commit creates the release, rights attestation and audit event together. Repeated publish calls do not create duplicate versions.

## Staging and upload

- Package maximum is 1 GiB. Admin sessions create UUID keys `staging/{upload-id}/package.ipa`; image sessions use `staging-assets/{asset-id}/asset`.
- In production, the API signs one R2 `PutObject` capability for the exact bucket/key/content length, `application/octet-stream` or validated image type, `If-None-Match: *`, and short expiry. The browser receives only that object capability and required headers. The Worker never buffers an entire production IPA.
- Completion reads R2 `HEAD` and checks exact declared size and maximum size before queueing. Local direct upload endpoints are enabled by local-only `.dev.vars` flags and capped at 10 MiB for IPA and 10 MiB for images.
- Client filenames, extensions and browser MIME are not trusted as package identity. Object names are server-generated and do not contain the submitted filename.

## Validation and metadata match

The API sends only upload ID and a random dispatch ticket to the protected workflow. The worker stores the ticket hash and returns the ticket once. The workflow exchanges a short-lived GitHub OIDC token for a single-use lease URL; the API marks a run ID/attempt and stores a hashed report nonce. The runner refuses redirects and downloads only that signed private object URL. It independently enforces the expected byte count and parses the IPA without extraction or code execution.

The validator computes SHA-256 over the staged file and reads bundle identifier, short version, build, minimum OS, display name and executable presence from the IPA. The server compares bundle ID against the target app and size against the upload session. All other metadata is strictly bounded and validated before state becomes `ready_for_review`. See [validator](validator.md).

## Review, rights, publish

An editor or admin may inspect detected metadata and set bounded release notes/channel. A bundle mismatch, validation error, duplicate version/build, missing icon, missing release fields or wrong size blocks publication. Only an admin may publish. The `confirmRights` action is recorded in `distribution_rights_attestations` with admin ID, release ID, timestamp and `v1` attestation marker. This records an administrator assertion; it does not adjudicate the underlying rights.

The public key is normalized from the validated bundle ID/version/digest, for example:

```text
published/com.example.reader/1.2.0/<sha256>.ipa
```

The key contains no user-provided path segment and is never reused for different bytes. After the public copy exists and is verified by R2 metadata, D1 commits the release and attestation. If the database transaction fails, the newly written copy is compensated. Public catalog endpoints and generated repository v1 query the same D1 records; staging objects are never returned.

## Failure and cleanup

Rejected or validation-failed releases are never public. Rejection removes the staging object after the DB state transition. An inspection job failure is reported through its OIDC report job as `validation_failed`; failure before a lease is established leaves the upload queued for retry until expiry. Expired uploads are not served publicly. Automated production expiry cleanup and multipart cleanup are operator deployment tasks, not part of this phase.

The iOS client still verifies the downloaded bytes' SHA-256, archive structure and metadata before producing `VerifiedPackage`; server validation does not replace client validation.
