import type { AdminUploadRecord } from "./adminContentRepository.js";
import { auditStatement } from "./adminRepository.js";

export async function insertPackageUpload(
  database: D1Database,
  input: {
    id: string; adminId: string; appId: string; stagingKey: string; size: number;
    nonceHash: string; expiresAt: string;
  },
): Promise<void> {
  await database.prepare(
    "INSERT INTO upload_jobs (id, admin_user_id, app_id, staging_object_key, state, expected_size, " +
    "validator_nonce_sha256, expires_at) VALUES (?, ?, ?, ?, 'uploading', ?, ?, ?)",
  ).bind(input.id, input.adminId, input.appId, input.stagingKey, input.size, input.nonceHash, input.expiresAt).run();
}

export async function getUpload(database: D1Database, id: string): Promise<AdminUploadRecord | null> {
  return database.prepare("SELECT * FROM upload_jobs WHERE id = ? LIMIT 1")
    .bind(id).first<AdminUploadRecord>();
}

export async function getUploadWithApp(database: D1Database, id: string) {
  return database.prepare(
    "SELECT u.*, a.bundle_identifier AS app_bundle_identifier, a.name AS app_name, a.published AS app_published, " +
    "a.icon_object_key AS app_icon_object_key FROM upload_jobs AS u JOIN apps AS a ON a.id = u.app_id " +
    "WHERE u.id = ? LIMIT 1",
  ).bind(id).first<AdminUploadRecord & {
    app_bundle_identifier: string; app_name: string; app_published: number; app_icon_object_key: string;
  }>();
}

export async function setUploadUploaded(
  database: D1Database,
  id: string,
  etag: string,
): Promise<boolean> {
  const result = await database.prepare(
    "UPDATE upload_jobs SET state = 'uploaded', object_etag = ?, completed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), " +
    "updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND state = 'uploading'",
  ).bind(etag, id).run();
  return (result.meta.changes ?? 0) === 1;
}

export async function markUploadQueued(database: D1Database, id: string, dispatchTicketHash: string): Promise<void> {
  await database.prepare(
    "UPDATE upload_jobs SET state = 'queued', validator_nonce_sha256 = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
    "WHERE id = ? AND state = 'uploaded'",
  ).bind(dispatchTicketHash, id).run();
}

export async function claimValidatorRun(
  database: D1Database,
  input: { id: string; runId: string; runAttempt: number; nonceHash: string },
): Promise<AdminUploadRecord | null> {
  const result = await database.prepare(
    "UPDATE upload_jobs SET state = 'validating', validator_run_id = ?, validator_run_attempt = ?, " +
    "validator_nonce_sha256 = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
    "WHERE id = ? AND state = 'queued' AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
  ).bind(input.runId, input.runAttempt, input.nonceHash, input.id).run();
  if ((result.meta.changes ?? 0) !== 1) return null;
  return getUpload(database, input.id);
}

export async function completeValidatorRun(
  database: D1Database,
  input: {
    id: string; runId: string; runAttempt: number; nonceHash: string; valid: boolean;
    bundleIdentifier?: string; version?: string; build?: string; minimumOS?: string;
    displayName?: string; size?: number; sha256?: string; errorCode?: string;
  },
): Promise<boolean> {
  const state = input.valid ? "ready_for_review" : "validation_failed";
  const result = await database.prepare(
    "UPDATE upload_jobs SET state = ?, detected_bundle_identifier = ?, detected_version = ?, detected_build = ?, " +
    "detected_minimum_ios = ?, detected_display_name = ?, actual_size = ?, sha256 = ?, validation_error_code = ?, " +
    "updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND state = 'validating' " +
    "AND validator_run_id = ? AND validator_run_attempt = ? AND validator_nonce_sha256 = ?",
  ).bind(
    state,
    input.bundleIdentifier ?? null,
    input.version ?? null,
    input.build ?? null,
    input.minimumOS ?? null,
    input.displayName ?? null,
    input.size ?? null,
    input.sha256 ?? null,
    input.errorCode ?? null,
    input.id,
    input.runId,
    input.runAttempt,
    input.nonceHash,
  ).run();
  return (result.meta.changes ?? 0) === 1;
}

export async function updateReleaseReview(
  database: D1Database,
  input: { id: string; releaseNotes: string; channel: "stable" | "beta" },
): Promise<boolean> {
  const result = await database.prepare(
    "UPDATE upload_jobs SET release_notes = ?, channel = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
    "WHERE id = ? AND state = 'ready_for_review'",
  ).bind(input.releaseNotes, input.channel, input.id).run();
  return (result.meta.changes ?? 0) === 1;
}

export async function beginPublish(database: D1Database, id: string): Promise<boolean> {
  const result = await database.prepare(
    "UPDATE upload_jobs SET state = 'publishing', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
    "WHERE id = ? AND state = 'ready_for_review'",
  ).bind(id).run();
  return (result.meta.changes ?? 0) === 1;
}

export async function resetPublish(database: D1Database, id: string): Promise<void> {
  await database.prepare(
    "UPDATE upload_jobs SET state = 'ready_for_review', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
    "WHERE id = ? AND state = 'publishing' AND published_object_key IS NULL",
  ).bind(id).run();
}

export async function commitPublishedRelease(
  database: D1Database,
  input: {
    uploadId: string; appId: string; versionId: string; objectKey: string;
    adminId: string; adminEmail: string; requestId: string; channel: "stable" | "beta";
    version: string; build: string; minimumOS: string; size: number; sha256: string; releaseNotes: string;
  },
): Promise<void> {
  const now = new Date().toISOString();
  await database.batch([
    database.prepare(
      "INSERT INTO versions (id, app_id, version, build, minimum_ios, ipa_object_key, sha256, size, " +
      "release_notes, channel, distribution_rights_attested, published_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)",
    ).bind(
      input.versionId, input.appId, input.version, input.build, input.minimumOS, input.objectKey,
      input.sha256, input.size, input.releaseNotes, input.channel, now,
    ),
    database.prepare(
      "INSERT INTO distribution_rights_attestations (id, upload_id, release_id, admin_user_id, attestation_version, confirmed) " +
      "VALUES (?, ?, ?, ?, 'v1', 1)",
    ).bind(crypto.randomUUID(), input.uploadId, input.versionId, input.adminId),
    database.prepare(
      "UPDATE apps SET published = 1, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
    ).bind(now, input.appId),
    database.prepare(
      "UPDATE upload_jobs SET state = 'published', published_object_key = ?, updated_at = ? " +
      "WHERE id = ? AND state = 'publishing'",
    ).bind(input.objectKey, now, input.uploadId),
    auditStatement(database, {
      id: crypto.randomUUID(), adminUserId: input.adminId, actorSubject: input.adminEmail,
      action: "release.published", resourceType: "release", resourceId: input.versionId, requestId: input.requestId,
    }),
  ]);
}

export async function rejectUpload(
  database: D1Database,
  input: { id: string; adminId: string; email: string; requestId: string },
): Promise<boolean> {
  const result = await database.batch([
    database.prepare(
      "UPDATE upload_jobs SET state = 'rejected', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
      "WHERE id = ? AND state IN ('uploading', 'uploaded', 'queued', 'validating', 'validation_failed', 'ready_for_review')",
    ).bind(input.id),
    auditStatement(database, {
      id: crypto.randomUUID(), adminUserId: input.adminId, actorSubject: input.email,
      action: "release.rejected", resourceType: "upload", resourceId: input.id, requestId: input.requestId,
    }),
  ]);
  return (result[0]?.meta.changes ?? 0) === 1;
}

export async function recordUploadEvent(
  database: D1Database,
  input: { adminId: string; email: string; action: string; uploadId: string; requestId: string },
): Promise<void> {
  await database.prepare(
    "INSERT INTO audit_logs (id, admin_user_id, actor_subject, action, resource_type, resource_id, request_id) " +
    "VALUES (?, ?, ?, ?, 'upload', ?, ?)",
  ).bind(crypto.randomUUID(), input.adminId, input.email, input.action, input.uploadId, input.requestId).run();
}
