import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";
import {
  categoryExists,
  createDraftApp,
  findAdminApp,
  findDeveloper,
  listAdminApps,
  listAdminCategories,
  listAdminRepositories,
  listRecentAudit,
  repositoryExists,
  updateDraftApp,
  type AdminAppRecord,
} from "../repositories/adminContentRepository.js";
import { auditStatement, writeAudit } from "../repositories/adminRepository.js";

const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/u;
const APP_ID = /^[a-z0-9][a-z0-9._-]{0,127}$/u;

export interface AppDraftInput {
  name: string;
  bundleIdentifier: string;
  developer: string;
  categoryId: string;
  description: string;
  shortDescription: string;
  repositoryId: string;
}

export async function getAdminDashboard(environment: WorkerEnvironment) {
  const [apps, releases, uploads, storage, activity] = await Promise.all([
    environment.DB.prepare("SELECT COUNT(*) AS value FROM apps WHERE deleted_at IS NULL").first<{ value: number }>(),
    environment.DB.prepare("SELECT COUNT(*) AS value FROM versions WHERE published_at IS NOT NULL").first<{ value: number }>(),
    environment.DB.prepare(
      "SELECT state, COUNT(*) AS value FROM upload_jobs WHERE state IN " +
      "('uploading', 'uploaded', 'queued', 'validating', 'validation_failed', 'ready_for_review', 'publishing') GROUP BY state",
    ).all<{ state: string; value: number }>(),
    environment.DB.prepare("SELECT COALESCE(SUM(size), 0) AS value FROM versions WHERE published_at IS NOT NULL").first<{ value: number }>(),
    listRecentAudit(environment.DB),
  ]);
  const appCounts = await environment.DB.prepare(
    "SELECT SUM(CASE WHEN published = 1 THEN 1 ELSE 0 END) AS published, " +
    "SUM(CASE WHEN published = 0 THEN 1 ELSE 0 END) AS drafts FROM apps WHERE deleted_at IS NULL",
  ).first<{ published: number; drafts: number }>();
  return {
    apps: apps?.value ?? 0,
    published: appCounts?.published ?? 0,
    drafts: appCounts?.drafts ?? 0,
    releases: releases?.value ?? 0,
    pendingUploads: (uploads.results ?? []).reduce((sum, row) => sum + row.value, 0),
    storageBytes: storage?.value ?? 0,
    recentActivity: activity,
  };
}

export async function getAdminApps(environment: WorkerEnvironment, query: string) {
  if (query.length > 100) throw new ApiError(400, "invalid_query", "Search must be 100 characters or fewer.");
  return listAdminApps(environment.DB, query);
}

export async function getAdminApp(environment: WorkerEnvironment, appId: string): Promise<AdminAppRecord> {
  if (!APP_ID.test(appId)) throw new ApiError(400, "invalid_app_id", "The application identifier is invalid.");
  const app = await findAdminApp(environment.DB, appId);
  if (!app) throw new ApiError(404, "not_found", "The application was not found.");
  return app;
}

export async function getAdminFormOptions(environment: WorkerEnvironment) {
  let repositories = await listAdminRepositories(environment.DB);
  if (repositories.length === 0) {
    let apiBase: URL;
    try { apiBase = new URL(environment.PUBLIC_API_BASE_URL ?? ""); }
    catch { throw new ApiError(503, "repository_configuration_missing", "Configure PUBLIC_API_BASE_URL before creating catalog records."); }
    if (apiBase.protocol !== "https:" || !apiBase.hostname || apiBase.username || apiBase.password || apiBase.search || apiBase.hash) {
      throw new ApiError(503, "repository_configuration_missing", "Configure PUBLIC_API_BASE_URL as an HTTPS origin.");
    }
    await environment.DB.prepare(
      "INSERT OR IGNORE INTO repositories (id, identifier, name, manifest_url, trust_level, description, icon_object_key) " +
      "VALUES ('repo-dreyze-official', 'com.dreyze.official', 'DreyzeStore Official', ?, 'official', " +
      "'Official DreyzeStore release catalog.', 'icons/repository-default.png')",
    ).bind(new URL("/api/v1/repository", apiBase).href).run();
    repositories = await listAdminRepositories(environment.DB);
  }
  const categories = await listAdminCategories(environment.DB);
  return { categories, repositories };
}

export async function createAppDraft(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  input: AppDraftInput,
) {
  validateDraft(input);
  if (!(await categoryExists(environment.DB, input.categoryId))) {
    throw new ApiError(400, "invalid_category", "Choose an existing category.");
  }
  if (!(await repositoryExists(environment.DB, input.repositoryId))) {
    throw new ApiError(400, "invalid_repository", "Choose an existing official source.");
  }
  let developerId = (await findDeveloper(environment.DB, input.developer))?.id;
  if (!developerId) developerId = "developer-" + crypto.randomUUID();
  const appId = "app-" + crypto.randomUUID();
  await createDraftApp(environment.DB, {
    developerId,
    developerName: input.developer,
    appId,
    bundleIdentifier: input.bundleIdentifier,
    name: input.name,
    shortDescription: input.shortDescription,
    description: input.description,
    categoryId: input.categoryId,
    repositoryId: input.repositoryId,
    iconObjectKey: "icons/pending/" + appId + ".png",
  });
  await writeAudit(environment.DB, {
    id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
    action: "app.created", resourceType: "app", resourceId: appId, requestId,
  });
  return getAdminApp(environment, appId);
}

export async function editAppDraft(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  appId: string,
  input: AppDraftInput,
) {
  validateDraft(input);
  const existing = await getAdminApp(environment, appId);
  const releaseCount = await environment.DB.prepare("SELECT COUNT(*) AS count FROM versions WHERE app_id = ?")
    .bind(appId).first<{ count: number }>();
  if (existing.bundleIdentifier !== input.bundleIdentifier && (releaseCount?.count ?? 0) > 0) {
    throw new ApiError(409, "bundle_identifier_locked", "Bundle ID cannot change after a release exists.");
  }
  if (existing.bundleIdentifier !== input.bundleIdentifier) {
    throw new ApiError(409, "bundle_identifier_migration_required", "Bundle ID changes require a separate migration operation.");
  }
  if (!(await categoryExists(environment.DB, input.categoryId))) {
    throw new ApiError(400, "invalid_category", "Choose an existing category.");
  }
  if (!(await repositoryExists(environment.DB, input.repositoryId))) {
    throw new ApiError(400, "invalid_repository", "Choose an existing official source.");
  }
  const developerId = (await findDeveloper(environment.DB, input.developer))?.id ?? "developer-" + crypto.randomUUID();
  const changed = await updateDraftApp(environment.DB, {
    appId,
    developerId,
    developerName: input.developer,
    name: input.name,
    shortDescription: input.shortDescription,
    description: input.description,
    categoryId: input.categoryId,
    repositoryId: input.repositoryId,
  });
  if (!changed) throw new ApiError(404, "not_found", "The application was not found.");
  await writeAudit(environment.DB, {
    id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
    action: "app.updated", resourceType: "app", resourceId: appId, requestId,
  });
  return getAdminApp(environment, appId);
}

export async function deleteDraftApp(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  appId: string,
) {
  const app = await getAdminApp(environment, appId);
  if (app.releaseCount > 0 || app.published) {
    throw new ApiError(409, "app_has_releases", "Applications with release history cannot be deleted. Unpublish them instead.");
  }
  const pending = await environment.DB.prepare(
    "SELECT 1 AS found FROM upload_jobs WHERE app_id = ? AND state NOT IN ('expired', 'rejected') LIMIT 1",
  ).bind(appId).first<{ found: number }>();
  if (pending) throw new ApiError(409, "app_has_pending_uploads", "Resolve or reject pending uploads before deleting this draft.");
  await environment.DB.batch([
    environment.DB.prepare("DELETE FROM featured WHERE app_id = ?").bind(appId),
    environment.DB.prepare(
      "UPDATE apps SET deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
      "WHERE id = ? AND deleted_at IS NULL",
    ).bind(appId),
    auditStatement(environment.DB, {
      id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
      action: "app.deleted", resourceType: "app", resourceId: appId, requestId,
    }),
  ]);
}

export async function unpublishApp(
  environment: WorkerEnvironment,
  admin: { id: string; email: string },
  requestId: string,
  appId: string,
) {
  const app = await getAdminApp(environment, appId);
  if (!app.published) return app;
  await environment.DB.batch([
    environment.DB.prepare(
      "UPDATE apps SET published = 0, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
    ).bind(appId),
    environment.DB.prepare("DELETE FROM featured WHERE app_id = ?").bind(appId),
    auditStatement(environment.DB, {
      id: crypto.randomUUID(), adminUserId: admin.id, actorSubject: admin.email,
      action: "app.unpublished", resourceType: "app", resourceId: appId, requestId,
    }),
  ]);
  return getAdminApp(environment, appId);
}

function validateDraft(input: AppDraftInput): void {
  if (!BUNDLE_ID.test(input.bundleIdentifier) || input.bundleIdentifier.length > 255) {
    throw new ApiError(400, "invalid_bundle_identifier", "Enter a valid bundle identifier.");
  }
  const limits: Array<[keyof AppDraftInput, number, boolean]> = [
    ["name", 160, true], ["developer", 200, true], ["categoryId", 80, true],
    ["description", 20_000, true], ["shortDescription", 160, true], ["repositoryId", 128, true],
  ];
  for (const [field, maxLength, required] of limits) {
    const value = input[field];
    if (typeof value !== "string" || value.trim().length > maxLength || (required && value.trim().length === 0)) {
      throw new ApiError(400, "invalid_app_metadata", "One or more application fields are missing or too long.", {
        [field]: [`Enter a value up to ${maxLength} characters.`],
      });
    }
  }
}
