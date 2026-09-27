import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";
import { writeAudit, auditStatement } from "../repositories/adminRepository.js";
import { presignStagingPut } from "./r2PresignService.js";
import { inspectImage } from "./imageInspection.js";

const APP_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/u;

export async function createAssetUpload(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  appId: string,
  input: { kind: "icon" | "screenshot"; size: number; contentType: "image/png" | "image/jpeg"; altText?: string },
) {
  if (!APP_ID_PATTERN.test(appId)) throw new ApiError(400, "invalid_app_id", "The application identifier is invalid.");
  if (!Number.isSafeInteger(input.size) || input.size < 1 || input.size > 10 * 1024 * 1024) {
    throw new ApiError(413, "image_size_not_allowed", "Images must be between 1 byte and 10 MiB.");
  }
  if (input.contentType !== "image/png" && input.contentType !== "image/jpeg") {
    throw new ApiError(415, "unsupported_image_type", "Use a PNG or JPEG image.");
  }
  const app = await environment.DB.prepare("SELECT id FROM apps WHERE id = ? AND deleted_at IS NULL LIMIT 1")
    .bind(appId).first<{ id: string }>();
  if (!app) throw new ApiError(404, "not_found", "The application was not found.");
  if (input.kind === "screenshot") {
    const count = await environment.DB.prepare("SELECT COUNT(*) AS count FROM screenshots WHERE app_id = ?")
      .bind(appId).first<{ count: number }>();
    const pending = await environment.DB.prepare(
      "SELECT COUNT(*) AS count FROM admin_asset_uploads WHERE app_id = ? AND kind = 'screenshot' AND state != 'expired'",
    ).bind(appId).first<{ count: number }>();
    if ((count?.count ?? 0) + (pending?.count ?? 0) >= 20) {
      throw new ApiError(409, "screenshot_limit", "An application can have at most 20 screenshots.");
    }
  }
  const id = crypto.randomUUID();
  const objectKey = `staging-assets/${id}/asset`;
  const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  await environment.DB.prepare(
    "INSERT INTO admin_asset_uploads (id, admin_user_id, app_id, kind, staging_object_key, expected_size, content_type, alt_text, state, expires_at) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'uploading', ?)",
  ).bind(id, admin.id, appId, input.kind, objectKey, input.size, input.contentType,
    input.altText?.trim().slice(0, 240) ?? "", expiresAt).run();
  let uploadURL: string;
  let requiredHeaders: Record<string, string>;
  if (environment.LOCAL_UPLOADS_ENABLED === "true") {
    uploadURL = new URL(`/api/v1/admin/assets/${id}/local`, environment.VALIDATOR_API_BASE_URL ?? "http://127.0.0.1:8787").href;
    requiredHeaders = { "Content-Type": input.contentType };
  } else {
    uploadURL = await presignStagingPut(environment, objectKey, input.size, input.contentType);
    requiredHeaders = { "Content-Type": input.contentType, "If-None-Match": "*" };
  }
  await writeAudit(environment.DB, {
    id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
    action: "asset.upload_created", resourceType: "app", resourceId: appId, requestId,
  });
  return { id, uploadURL, requiredHeaders, expectedSize: input.size, expiresAt };
}

export async function acceptLocalAssetBody(environment: WorkerEnvironment, assetId: string, request: Request) {
  if (environment.LOCAL_UPLOADS_ENABLED !== "true") throw new ApiError(404, "not_found", "The resource was not found.");
  const asset = await environment.DB.prepare("SELECT * FROM admin_asset_uploads WHERE id = ? AND state = 'uploading' LIMIT 1")
    .bind(assetId).first<{ staging_object_key: string; expected_size: number; content_type: string; expires_at: string }>();
  if (!asset || Date.parse(asset.expires_at) <= Date.now()) throw new ApiError(409, "asset_upload_expired", "The image upload has expired.");
  if (asset.expected_size > 10 * 1024 * 1024 || Number(request.headers.get("Content-Length")) !== asset.expected_size || !request.body) {
    throw new ApiError(400, "asset_size_mismatch", "The uploaded image size does not match its upload session.");
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength !== asset.expected_size) throw new ApiError(400, "asset_size_mismatch", "The uploaded image size does not match its upload session.");
  await environment.STAGING_ASSETS.put(asset.staging_object_key, bytes, {
    httpMetadata: { contentType: asset.content_type },
  });
}

export async function completeAssetUpload(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  assetId: string,
) {
  const asset = await environment.DB.prepare("SELECT * FROM admin_asset_uploads WHERE id = ? AND state = 'uploading' LIMIT 1")
    .bind(assetId).first<{
      id: string; admin_user_id: string; app_id: string; kind: "icon" | "screenshot";
      staging_object_key: string; expected_size: number; content_type: "image/png" | "image/jpeg";
      alt_text: string; expires_at: string;
    }>();
  if (!asset) throw new ApiError(404, "not_found", "The image upload was not found.");
  if (Date.parse(asset.expires_at) <= Date.now()) throw new ApiError(410, "asset_upload_expired", "The image upload has expired.");
  const stored = await environment.STAGING_ASSETS.get(asset.staging_object_key);
  if (!stored || stored.size !== asset.expected_size || stored.size > 10 * 1024 * 1024) {
    throw new ApiError(400, "asset_size_mismatch", "The private staged image size does not match its upload session.");
  }
  const bytes = new Uint8Array(await stored.arrayBuffer());
  const inspected = inspectImage(bytes, asset.content_type, asset.kind);
  const objectKey = `${asset.kind === "icon" ? "icons" : "screenshots"}/${asset.app_id}/${asset.id}.${inspected.extension}`;
  const existingIcon = asset.kind === "icon"
    ? await environment.DB.prepare("SELECT icon_object_key FROM apps WHERE id = ? LIMIT 1")
      .bind(asset.app_id).first<{ icon_object_key: string }>()
    : null;
  await environment.PUBLIC_ASSETS.put(objectKey, bytes, {
    httpMetadata: { contentType: inspected.contentType, cacheControl: "public, max-age=31536000, immutable" },
  });
  try {
    if (asset.kind === "icon") {
      await environment.DB.batch([
        environment.DB.prepare(
          "UPDATE apps SET icon_object_key = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ? AND deleted_at IS NULL",
        ).bind(objectKey, asset.app_id),
        environment.DB.prepare("UPDATE admin_asset_uploads SET state = 'published' WHERE id = ? AND state = 'uploading'").bind(asset.id),
        auditStatement(environment.DB, {
          id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
          action: "asset.icon_uploaded", resourceType: "app", resourceId: asset.app_id, requestId,
        }),
      ]);
    } else {
      await environment.DB.batch([
        environment.DB.prepare(
          "INSERT INTO screenshots (id, app_id, object_key, width, height, alt_text, ordinal) " +
          "SELECT ?, ?, ?, ?, ?, ?, COALESCE(MAX(ordinal) + 1, 0) FROM screenshots WHERE app_id = ?",
        ).bind(asset.id, asset.app_id, objectKey, inspected.width, inspected.height,
          asset.alt_text || "Application screenshot", asset.app_id),
        environment.DB.prepare("UPDATE apps SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?")
          .bind(asset.app_id),
        environment.DB.prepare("UPDATE admin_asset_uploads SET state = 'published' WHERE id = ? AND state = 'uploading'").bind(asset.id),
        auditStatement(environment.DB, {
          id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
          action: "asset.screenshot_uploaded", resourceType: "app", resourceId: asset.app_id, requestId,
        }),
      ]);
    }
  } catch (error) {
    await environment.PUBLIC_ASSETS.delete(objectKey);
    if (error instanceof Error && /UNIQUE constraint failed: screenshots/u.test(error.message)) {
      throw new ApiError(409, "screenshot_limit", "The screenshot list changed. Refresh and try again.");
    }
    throw error;
  }
  if (existingIcon?.icon_object_key && existingIcon.icon_object_key !== objectKey &&
      existingIcon.icon_object_key !== "icons/pending/" + asset.app_id + ".png") {
    const stillReferenced = await environment.DB.prepare("SELECT 1 AS found FROM apps WHERE icon_object_key = ? LIMIT 1")
      .bind(existingIcon.icon_object_key).first<{ found: number }>();
    if (!stillReferenced) await environment.PUBLIC_ASSETS.delete(existingIcon.icon_object_key);
  }
  await environment.STAGING_ASSETS.delete(asset.staging_object_key);
  return {
    id: asset.id,
    kind: asset.kind,
    width: inspected.width,
    height: inspected.height,
    url: new URL(objectKey.split("/").map(encodeURIComponent).join("/"), ensureBase(environment.PUBLIC_ASSETS_BASE_URL)).href,
  };
}

export async function deleteScreenshot(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  appId: string,
  screenshotId: string,
) {
  const row = await environment.DB.prepare("SELECT object_key FROM screenshots WHERE id = ? AND app_id = ? LIMIT 1")
    .bind(screenshotId, appId).first<{ object_key: string }>();
  if (!row) throw new ApiError(404, "not_found", "The screenshot was not found.");
  const screenshots = await environment.DB.prepare("SELECT id, ordinal FROM screenshots WHERE app_id = ? ORDER BY ordinal, id")
    .bind(appId).all<{ id: string; ordinal: number }>();
  const remaining = (screenshots.results ?? []).filter((item) => item.id !== screenshotId);
  const statements: D1PreparedStatement[] = [
    environment.DB.prepare("DELETE FROM screenshots WHERE id = ? AND app_id = ?").bind(screenshotId, appId),
    environment.DB.prepare("UPDATE apps SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?").bind(appId),
  ];
  statements.push(...ordinalStatements(environment.DB, appId, remaining.map((item) => item.id)));
  statements.push(auditStatement(environment.DB, {
    id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
    action: "asset.screenshot_deleted", resourceType: "app", resourceId: appId, requestId,
  }));
  await environment.DB.batch(statements);
  await environment.PUBLIC_ASSETS.delete(row.object_key);
  return { deleted: true };
}

export async function reorderScreenshots(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  appId: string,
  screenshotIds: string[],
) {
  const current = await environment.DB.prepare("SELECT id FROM screenshots WHERE app_id = ? ORDER BY ordinal, id")
    .bind(appId).all<{ id: string }>();
  const currentIds = (current.results ?? []).map((row) => row.id);
  if (screenshotIds.length !== currentIds.length || new Set(screenshotIds).size !== screenshotIds.length ||
      screenshotIds.some((id) => !currentIds.includes(id))) {
    throw new ApiError(400, "invalid_screenshot_order", "Provide every screenshot exactly once.");
  }
  await environment.DB.batch([
    ...ordinalStatements(environment.DB, appId, screenshotIds),
    environment.DB.prepare("UPDATE apps SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?").bind(appId),
    auditStatement(environment.DB, {
      id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
      action: "asset.screenshots_reordered", resourceType: "app", resourceId: appId, requestId,
    }),
  ]);
  return { screenshotIds };
}

export async function listScreenshots(environment: WorkerEnvironment, appId: string) {
  const result = await environment.DB.prepare(
    "SELECT id, object_key, width, height, alt_text AS altText, ordinal FROM screenshots WHERE app_id = ? ORDER BY ordinal, id",
  ).bind(appId).all<{ id: string; object_key: string; width: number; height: number; altText: string; ordinal: number }>();
  const base = ensureBase(environment.PUBLIC_ASSETS_BASE_URL);
  return (result.results ?? []).map((row) => ({
    id: row.id,
    url: new URL(row.object_key.split("/").map(encodeURIComponent).join("/"), base).href,
    width: row.width,
    height: row.height,
    altText: row.altText,
    ordinal: row.ordinal,
  }));
}

export async function setFeaturedApps(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  sectionKey: string,
  appIds: string[],
) {
  const validSections = new Set(["hero", "editors-picks", "new-releases", "recently-updated", "popular"]);
  if (!validSections.has(sectionKey) || appIds.length > 50 || new Set(appIds).size !== appIds.length ||
      appIds.some((id) => !APP_ID_PATTERN.test(id))) {
    throw new ApiError(400, "invalid_featured_order", "Choose a valid section and at most 50 unique applications.");
  }
  const placeholders = appIds.map(() => "?").join(", ");
  if (appIds.length) {
    const result = await environment.DB.prepare(
      "SELECT COUNT(*) AS count FROM apps WHERE id IN (" + placeholders + ") AND published = 1 AND deleted_at IS NULL " +
      "AND EXISTS (SELECT 1 FROM versions WHERE versions.app_id = apps.id AND published_at IS NOT NULL)",
    ).bind(...appIds).first<{ count: number }>();
    if (result?.count !== appIds.length) throw new ApiError(409, "featured_app_unpublished", "Featured entries must be published applications.");
  }
  const statements: D1PreparedStatement[] = [environment.DB.prepare("DELETE FROM featured WHERE section_key = ?").bind(sectionKey)];
  for (const [ordinal, id] of appIds.entries()) {
    statements.push(environment.DB.prepare("INSERT INTO featured (id, section_key, app_id, ordinal) VALUES (?, ?, ?, ?)")
      .bind(crypto.randomUUID(), sectionKey, id, ordinal));
  }
  statements.push(auditStatement(environment.DB, {
    id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
    action: "featured.updated", resourceType: "featured", resourceId: sectionKey, requestId,
  }));
  await environment.DB.batch(statements);
  return getFeaturedApps(environment, sectionKey);
}

export async function getFeaturedApps(environment: WorkerEnvironment, sectionKey?: string) {
  const where = sectionKey ? "WHERE f.section_key = ?" : "";
  const statement = environment.DB.prepare(
    "SELECT f.section_key AS sectionKey, f.ordinal, a.id AS appId, a.name, a.bundle_identifier AS bundleIdentifier " +
    "FROM featured AS f JOIN apps AS a ON a.id = f.app_id " + where + " ORDER BY f.section_key, f.ordinal",
  );
  const result = await (sectionKey ? statement.bind(sectionKey) : statement).all<{
    sectionKey: string; ordinal: number; appId: string; name: string; bundleIdentifier: string;
  }>();
  return result.results ?? [];
}

function ordinalStatements(database: D1Database, appId: string, orderedIds: string[]): D1PreparedStatement[] {
  const temporary = orderedIds.map((id, index) => database.prepare("UPDATE screenshots SET ordinal = ? WHERE app_id = ? AND id = ?")
    .bind(100_000 + index, appId, id));
  const final = orderedIds.map((id, index) => database.prepare("UPDATE screenshots SET ordinal = ? WHERE app_id = ? AND id = ?")
    .bind(index, appId, id));
  return [...temporary, ...final];
}

function ensureBase(value: string): URL {
  const base = new URL(value);
  if (base.protocol !== "https:" || !base.hostname || base.username || base.password || base.search || base.hash) {
    throw new ApiError(503, "service_configuration_error", "Public asset delivery is not configured.");
  }
  if (!base.pathname.endsWith("/")) base.pathname += "/";
  return base;
}
