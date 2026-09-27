import { isSemanticVersion } from "@dreyzestore/shared";
import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";
import { writeAudit } from "../repositories/adminRepository.js";
import {
  beginPublish,
  claimValidatorRun,
  commitPublishedRelease,
  completeValidatorRun,
  getUpload,
  getUploadWithApp,
  insertPackageUpload,
  markUploadQueued,
  recordUploadEvent,
  rejectUpload,
  resetPublish,
  setUploadUploaded,
  updateReleaseReview,
} from "../repositories/publishingRepository.js";
import { dispatchPackageValidator } from "./githubDispatchService.js";
import { presignStagingGet, presignStagingPut } from "./r2PresignService.js";
import { constantTimeHexEquals, randomToken, sha256Hex } from "../security/crypto.js";
import { verifyValidatorOidc } from "../security/githubOidc.js";

const MAX_PACKAGE_BYTES = 1_073_741_824;
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/u;
const BUNDLE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/u;
const BUILD_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/u;
const OS_PATTERN = /^[0-9]{1,3}(?:\.[0-9]{1,3}){1,2}$/u;
const HASH_PATTERN = /^[a-f0-9]{64}$/u;

export async function createPackageUpload(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  appId: string,
  input: { size: number },
) {
  if (!ID_PATTERN.test(appId)) throw new ApiError(400, "invalid_app_id", "The application identifier is invalid.");
  if (!Number.isSafeInteger(input.size) || input.size < 1 || input.size > MAX_PACKAGE_BYTES) {
    throw new ApiError(413, "package_size_not_allowed", "The package must be between 1 byte and 1 GiB.");
  }
  const app = await environment.DB.prepare("SELECT id FROM apps WHERE id = ? AND deleted_at IS NULL LIMIT 1")
    .bind(appId).first<{ id: string }>();
  if (!app) throw new ApiError(404, "not_found", "The application was not found.");

  const id = crypto.randomUUID();
  const stagingKey = "staging/" + id + "/package.ipa";
  const nonce = randomToken();
  const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  await insertPackageUpload(environment.DB, {
    id, adminId: admin.id, appId, stagingKey, size: input.size,
    nonceHash: await sha256Hex(nonce), expiresAt,
  });
  let uploadURL: string;
  let requiredHeaders: Record<string, string>;
  if (environment.LOCAL_UPLOADS_ENABLED === "true") {
    const base = environment.VALIDATOR_API_BASE_URL ?? "http://127.0.0.1:8787";
    uploadURL = new URL(`/api/v1/admin/uploads/${id}/local`, base).href;
    requiredHeaders = { "Content-Type": "application/octet-stream" };
  } else {
    uploadURL = await presignStagingPut(environment, stagingKey, input.size);
    requiredHeaders = { "Content-Type": "application/octet-stream", "If-None-Match": "*" };
  }
  await writeAudit(environment.DB, {
    id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
    action: "upload.created", resourceType: "upload", resourceId: id, requestId,
  });
  return { id, state: "uploading" as const, expectedSize: input.size, expiresAt, uploadURL, requiredHeaders };
}

export async function acceptLocalPackageBody(
  environment: WorkerEnvironment,
  uploadId: string,
  request: Request,
): Promise<void> {
  if (environment.LOCAL_UPLOADS_ENABLED !== "true") {
    throw new ApiError(404, "not_found", "The resource was not found.");
  }
  const upload = await getUpload(environment.DB, uploadId);
  if (!upload || upload.state !== "uploading" || Date.parse(upload.expires_at) <= Date.now()) {
    throw new ApiError(409, "upload_state_conflict", "The upload is no longer accepting data.");
  }
  if (upload.expected_size > 10 * 1024 * 1024) {
    throw new ApiError(413, "local_upload_limit", "Local development uploads are limited to 10 MiB.");
  }
  const contentLength = Number(request.headers.get("Content-Length"));
  if (!Number.isSafeInteger(contentLength) || contentLength !== upload.expected_size || !request.body) {
    throw new ApiError(400, "upload_size_mismatch", "The uploaded file size does not match the upload session.");
  }
  const countedBody = capStream(request.body, upload.expected_size);
  const stored = await environment.STAGING_ASSETS.put(upload.staging_object_key, countedBody, {
    httpMetadata: { contentType: "application/octet-stream", contentDisposition: "attachment" },
  });
  if (stored.size !== upload.expected_size) {
    await environment.STAGING_ASSETS.delete(upload.staging_object_key);
    throw new ApiError(400, "upload_size_mismatch", "The uploaded file size does not match the upload session.");
  }
}

export async function completePackageUpload(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  uploadId: string,
) {
  const upload = await getUpload(environment.DB, uploadId);
  if (!upload || !ID_PATTERN.test(uploadId)) throw new ApiError(404, "not_found", "The upload was not found.");
  if (upload.state === "queued" || upload.state === "validating" || upload.state === "ready_for_review") {
    return safeUpload(upload);
  }
  if (upload.state !== "uploading" && upload.state !== "uploaded") {
    throw new ApiError(409, "upload_state_conflict", "The upload cannot be completed in its current state.");
  }
  if (Date.parse(upload.expires_at) <= Date.now()) throw new ApiError(410, "upload_expired", "The upload session has expired.");
  const object = await environment.STAGING_ASSETS.head(upload.staging_object_key);
  if (!object || object.size !== upload.expected_size || object.size < 1 || object.size > MAX_PACKAGE_BYTES) {
    await environment.STAGING_ASSETS.delete(upload.staging_object_key);
    throw new ApiError(400, "upload_size_mismatch", "The private staged package size does not match the upload session.");
  }
  if (upload.state === "uploading") {
    const changed = await setUploadUploaded(environment.DB, uploadId, object.etag);
    if (!changed) throw new ApiError(409, "upload_state_conflict", "The upload was completed by another request.");
  }
  const dispatchTicket = randomToken();
  await markUploadQueued(environment.DB, uploadId, await sha256Hex(dispatchTicket));
  if (environment.LOCAL_VALIDATOR_ENABLED !== "true") {
    try {
      await dispatchPackageValidator(environment, uploadId, dispatchTicket);
    } catch (error) {
      await environment.DB.prepare(
        "UPDATE upload_jobs SET state = 'uploaded' WHERE id = ? AND state = 'queued'",
      ).bind(uploadId).run();
      throw error;
    }
  }
  await recordUploadEvent(environment.DB, {
    adminId: admin.id, email: admin.email, action: "upload.queued", uploadId, requestId,
  });
  return {
    ...safeUpload({ ...upload, state: "queued" }),
    validator: "queued" as const,
    ...(environment.LOCAL_VALIDATOR_ENABLED === "true" ? { dispatchTicket } : {}),
  };
}

export async function requestValidatorLease(environment: WorkerEnvironment, uploadId: string, token: string, dispatchTicket: string) {
  const identity = await verifyValidatorOidc(environment, token);
  const upload = await getUpload(environment.DB, uploadId);
  if (!upload || upload.state !== "queued" || Date.parse(upload.expires_at) <= Date.now()) {
    throw new ApiError(409, "validator_job_unavailable", "This upload is not available for validation.");
  }
  if (!constantTimeHexEquals(await sha256Hex(dispatchTicket), upload.validator_nonce_sha256)) {
    throw new ApiError(401, "validator_job_unauthenticated", "The validator dispatch was not accepted.");
  }
  const app = await environment.DB.prepare("SELECT bundle_identifier FROM apps WHERE id = ? LIMIT 1")
    .bind(upload.app_id).first<{ bundle_identifier: string }>();
  if (!app) throw new ApiError(404, "not_found", "The application was not found.");
  const downloadURL = await presignStagingGet(environment, upload.staging_object_key);
  const nonce = randomToken();
  const claimed = await claimValidatorRun(environment.DB, {
    id: uploadId, runId: identity.runId, runAttempt: identity.runAttempt, nonceHash: await sha256Hex(nonce),
  });
  if (!claimed) throw new ApiError(409, "validator_job_unavailable", "This upload was claimed by another validation run.");
  return {
    uploadId,
    downloadURL,
    reportNonce: nonce,
    expectedSize: upload.expected_size,
    expectedBundleIdentifier: app.bundle_identifier,
    expiresAt: upload.expires_at,
  };
}

export interface ValidatorReport {
  reportNonce?: unknown;
  result?: unknown;
  bundleIdentifier?: unknown;
  version?: unknown;
  build?: unknown;
  minimumOS?: unknown;
  displayName?: unknown;
  size?: unknown;
  sha256?: unknown;
  errorCode?: unknown;
}

export async function acceptValidatorReport(
  environment: WorkerEnvironment,
  uploadId: string,
  token: string,
  input: ValidatorReport,
) {
  const identity = await verifyValidatorOidc(environment, token);
  const upload = await getUpload(environment.DB, uploadId);
  if (!upload || upload.state !== "validating" || !upload.validator_run_id ||
      upload.validator_run_id !== identity.runId || upload.validator_run_attempt !== identity.runAttempt) {
    throw new ApiError(409, "validator_job_unavailable", "This validation result does not match an active job.");
  }
  if (typeof input.reportNonce !== "string" || !constantTimeHexEquals(
    await sha256Hex(input.reportNonce), upload.validator_nonce_sha256,
  )) {
    throw new ApiError(401, "validator_report_unauthenticated", "The validation result was not accepted.");
  }
  if (input.result === "failed") {
    const failureCode = typeof input.errorCode === "string" && /^[a-z_]{1,64}$/u.test(input.errorCode)
      ? input.errorCode : "package_invalid";
    const accepted = await completeValidatorRun(environment.DB, {
      id: uploadId, runId: identity.runId, runAttempt: identity.runAttempt,
      nonceHash: upload.validator_nonce_sha256, valid: false, errorCode: failureCode,
    });
    if (!accepted) throw new ApiError(409, "validator_job_unavailable", "This validation result was already processed.");
    await writeAudit(environment.DB, {
      id: crypto.randomUUID(), adminUserId: null, actorSubject: "trusted-validator",
      action: "upload.validation_failed", resourceType: "upload", resourceId: uploadId,
    });
    return { state: "validation_failed" as const };
  }
  if (input.result !== "passed" || !validReportFields(input)) {
    throw new ApiError(400, "invalid_validator_report", "The validation report is malformed.");
  }
  const app = await environment.DB.prepare("SELECT bundle_identifier FROM apps WHERE id = ? LIMIT 1")
    .bind(upload.app_id).first<{ bundle_identifier: string }>();
  if (!app) throw new ApiError(404, "not_found", "The application was not found.");
  const bundleMatches = input.bundleIdentifier === app.bundle_identifier;
  const sizeMatches = input.size === upload.expected_size;
  const accepted = await completeValidatorRun(environment.DB, {
    id: uploadId,
    runId: identity.runId,
    runAttempt: identity.runAttempt,
    nonceHash: upload.validator_nonce_sha256,
    valid: bundleMatches && sizeMatches,
    bundleIdentifier: input.bundleIdentifier as string,
    version: input.version as string,
    build: input.build as string,
    minimumOS: input.minimumOS as string,
    displayName: input.displayName as string,
    size: input.size as number,
    sha256: input.sha256 as string,
    errorCode: !bundleMatches ? "bundle_identifier_mismatch" : !sizeMatches ? "package_size_mismatch" : undefined,
  });
  if (!accepted) throw new ApiError(409, "validator_job_unavailable", "This validation result was already processed.");
  await writeAudit(environment.DB, {
    id: crypto.randomUUID(), adminUserId: null, actorSubject: "trusted-validator",
    action: bundleMatches && sizeMatches ? "upload.validation_passed" : "upload.validation_failed",
    resourceType: "upload", resourceId: uploadId,
  });
  return {
    state: bundleMatches && sizeMatches ? "ready_for_review" as const : "validation_failed" as const,
    metadataMatches: bundleMatches && sizeMatches,
  };
}

export async function getAdminUpload(environment: WorkerEnvironment, id: string) {
  const upload = await getUploadWithApp(environment.DB, id);
  if (!upload) throw new ApiError(404, "not_found", "The upload was not found.");
  const attestation = await environment.DB.prepare(
    "SELECT 1 AS exists_flag FROM distribution_rights_attestations WHERE upload_id = ? LIMIT 1",
  ).bind(id).first<{ exists_flag: number }>();
  return {
    id: upload.id,
    appId: upload.app_id,
    appName: upload.app_name,
    appBundleIdentifier: upload.app_bundle_identifier,
    state: upload.state,
    expectedSize: upload.expected_size,
    detectedPackage: upload.detected_bundle_identifier ? {
      bundleIdentifier: upload.detected_bundle_identifier,
      version: upload.detected_version,
      build: upload.detected_build,
      minimumOS: upload.detected_minimum_ios,
      displayName: upload.detected_display_name,
      size: upload.actual_size,
      sha256: upload.sha256,
    } : null,
    validationError: upload.validation_error_code,
    releaseNotes: upload.release_notes,
    channel: upload.channel,
    hasRightsAttestation: Boolean(attestation),
    expiresAt: upload.expires_at,
    createdAt: upload.created_at,
  };
}

export async function saveReleaseReview(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  uploadId: string,
  input: { releaseNotes: string; channel: "stable" | "beta" },
) {
  if (input.releaseNotes.length > 10_000 || (input.channel !== "stable" && input.channel !== "beta")) {
    throw new ApiError(400, "invalid_release", "Release notes or release channel are invalid.");
  }
  const changed = await updateReleaseReview(environment.DB, { id: uploadId, ...input });
  if (!changed) throw new ApiError(409, "release_not_reviewable", "This upload is not ready for release review.");
  await recordUploadEvent(environment.DB, {
    adminId: admin.id, email: admin.email, action: "release.review_updated", uploadId, requestId,
  });
  return getAdminUpload(environment, uploadId);
}

export async function publishRelease(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  uploadId: string,
  confirmRights: boolean,
) {
  if (!confirmRights) throw new ApiError(400, "rights_attestation_required", "Confirm distribution rights before publishing.");
  const upload = await getUploadWithApp(environment.DB, uploadId);
  if (!upload || upload.state !== "ready_for_review") {
    throw new ApiError(409, "release_not_reviewable", "Only a validated release under review can be published.");
  }
  if (!upload.detected_bundle_identifier || upload.detected_bundle_identifier !== upload.app_bundle_identifier) {
    throw new ApiError(409, "bundle_identifier_mismatch", "The package bundle identifier does not match this application.");
  }
  if (!upload.detected_version || !isSemanticVersion(upload.detected_version) ||
      !upload.detected_build || !BUILD_PATTERN.test(upload.detected_build) ||
      !upload.detected_minimum_ios || !OS_PATTERN.test(upload.detected_minimum_ios) ||
      !upload.sha256 || !HASH_PATTERN.test(upload.sha256) || upload.actual_size !== upload.expected_size) {
    throw new ApiError(409, "package_metadata_invalid", "The validated package metadata is incomplete.");
  }
  if (upload.app_icon_object_key.startsWith("icons/pending/")) {
    throw new ApiError(409, "app_icon_required", "Upload an application icon before publishing.");
  }
  const icon = await environment.PUBLIC_ASSETS.head(upload.app_icon_object_key);
  if (!icon) throw new ApiError(409, "app_icon_missing", "The application icon is unavailable in public asset storage.");
  const duplicate = await environment.DB.prepare(
    "SELECT id FROM versions WHERE app_id = ? AND version = ? AND build = ? LIMIT 1",
  ).bind(upload.app_id, upload.detected_version, upload.detected_build).first<{ id: string }>();
  if (duplicate) throw new ApiError(409, "duplicate_release", "This version and build already exist for the application.");
  if (!upload.object_etag || !upload.staging_object_key.startsWith("staging/")) {
    throw new ApiError(409, "staged_package_missing", "The validated staging package is unavailable.");
  }
  const claimed = await beginPublish(environment.DB, uploadId);
  if (!claimed) throw new ApiError(409, "release_not_reviewable", "Another request has already started publishing this release.");

  const versionId = "version-" + crypto.randomUUID();
  const safeVersionPath = upload.detected_version.replace(/[^A-Za-z0-9._-]/gu, "_");
  const objectKey = `packages/${upload.app_id}/${safeVersionPath}/${upload.sha256}.ipa`;
  let copied = false;
  try {
    const source = await environment.STAGING_ASSETS.get(upload.staging_object_key, {
      onlyIf: { etagMatches: upload.object_etag },
    });
    if (!source || !("body" in source) || source.size !== upload.expected_size) {
      throw new ApiError(409, "staged_package_changed", "The staged package changed after validation.");
    }
    await environment.PUBLIC_ASSETS.put(objectKey, source.body, {
      httpMetadata: { contentType: "application/octet-stream", contentDisposition: "attachment" },
      customMetadata: {
        sha256: upload.sha256,
        bundleIdentifier: upload.detected_bundle_identifier,
        version: upload.detected_version,
        build: upload.detected_build,
      },
    });
    copied = true;
    const published = await environment.PUBLIC_ASSETS.head(objectKey);
    if (!published || published.size !== upload.expected_size) {
      throw new ApiError(503, "distribution_copy_failed", "The release package could not be verified in distribution storage.");
    }
    await commitPublishedRelease(environment.DB, {
      uploadId, appId: upload.app_id, versionId, objectKey, adminId: admin.id,
      adminEmail: admin.email, requestId, channel: upload.channel,
      version: upload.detected_version, build: upload.detected_build,
      minimumOS: upload.detected_minimum_ios, size: upload.actual_size!, sha256: upload.sha256,
      releaseNotes: upload.release_notes,
    });
  } catch (error) {
    if (copied) await environment.PUBLIC_ASSETS.delete(objectKey);
    await resetPublish(environment.DB, uploadId);
    if (error instanceof ApiError) throw error;
    if (error instanceof Error && /UNIQUE constraint failed: versions\.app_id, versions\.version, versions\.build/u.test(error.message)) {
      throw new ApiError(409, "duplicate_release", "This version and build already exist for the application.");
    }
    throw new ApiError(503, "publish_failed", "The release could not be published. Try again after checking storage.");
  }
  await environment.STAGING_ASSETS.delete(upload.staging_object_key);
  return { id: versionId, state: "published" as const, bundleIdentifier: upload.detected_bundle_identifier,
    version: upload.detected_version, build: upload.detected_build, sha256: upload.sha256, size: upload.actual_size };
}

export async function rejectPackageUpload(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  uploadId: string,
) {
  const upload = await getUpload(environment.DB, uploadId);
  if (!upload || !(await rejectUpload(environment.DB, { id: uploadId, adminId: admin.id, email: admin.email, requestId }))) {
    throw new ApiError(409, "upload_state_conflict", "This upload cannot be rejected in its current state.");
  }
  await environment.STAGING_ASSETS.delete(upload.staging_object_key);
  return { id: uploadId, state: "rejected" as const };
}

function validReportFields(input: ValidatorReport): boolean {
  return typeof input.bundleIdentifier === "string" && BUNDLE_PATTERN.test(input.bundleIdentifier) &&
    typeof input.version === "string" && isSemanticVersion(input.version) &&
    typeof input.build === "string" && BUILD_PATTERN.test(input.build) &&
    typeof input.minimumOS === "string" && OS_PATTERN.test(input.minimumOS) &&
    typeof input.displayName === "string" && input.displayName.length > 0 && input.displayName.length <= 160 &&
    typeof input.size === "number" && Number.isSafeInteger(input.size) && input.size > 0 && input.size <= MAX_PACKAGE_BYTES &&
    typeof input.sha256 === "string" && HASH_PATTERN.test(input.sha256);
}

function safeUpload(upload: {
  id: string; state: string; expected_size: number; expires_at: string; sha256: string | null;
}) {
  return { id: upload.id, state: upload.state, expectedSize: upload.expected_size,
    sha256: upload.sha256, expiresAt: upload.expires_at };
}

function capStream(input: ReadableStream<Uint8Array>, expected: number): ReadableStream<Uint8Array> {
  const reader = input.getReader();
  let total = 0;
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      const next = await reader.read();
      if (next.done) {
        if (total !== expected) controller.error(new ApiError(400, "upload_size_mismatch", "The uploaded file size did not match the session."));
        else controller.close();
        reader.releaseLock();
        return;
      }
      total += next.value.byteLength;
      if (total > expected) {
        await reader.cancel();
        reader.releaseLock();
        controller.error(new ApiError(413, "upload_size_mismatch", "The uploaded file exceeded the session size."));
        return;
      }
      controller.enqueue(next.value);
    },
    async cancel(reason) { await reader.cancel(reason); },
  });
}
