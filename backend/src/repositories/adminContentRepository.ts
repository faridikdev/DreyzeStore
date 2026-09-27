export interface AdminAppRecord {
  id: string;
  bundleIdentifier: string;
  name: string;
  shortDescription: string;
  description: string;
  developer: string;
  developerId: string;
  categoryId: string;
  category: string;
  repositoryId: string;
  repository: string;
  published: boolean;
  releaseCount: number;
  latestVersion: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface AdminUploadRecord {
  id: string;
  app_id: string;
  staging_object_key: string;
  state: string;
  expected_size: number;
  expected_content_type: string;
  object_etag: string | null;
  validator_nonce_sha256: string;
  validator_run_id: string | null;
  validator_run_attempt: number | null;
  detected_bundle_identifier: string | null;
  detected_version: string | null;
  detected_build: string | null;
  detected_minimum_ios: string | null;
  detected_display_name: string | null;
  actual_size: number | null;
  sha256: string | null;
  validation_error_code: string | null;
  release_notes: string;
  channel: "stable" | "beta";
  published_object_key: string | null;
  expires_at: string;
  created_at: string;
}

export async function findDeveloper(database: D1Database, name: string): Promise<{ id: string } | null> {
  return database.prepare("SELECT id FROM developers WHERE name = ? COLLATE NOCASE LIMIT 1")
    .bind(name).first<{ id: string }>();
}

export async function repositoryExists(database: D1Database, id: string): Promise<boolean> {
  const row = await database.prepare(
    "SELECT id FROM repositories WHERE id = ? AND trust_level = 'official' LIMIT 1",
  ).bind(id).first<{ id: string }>();
  return row !== null;
}

export async function categoryExists(database: D1Database, id: string): Promise<boolean> {
  const row = await database.prepare("SELECT id FROM categories WHERE id = ? LIMIT 1")
    .bind(id).first<{ id: string }>();
  return row !== null;
}

export async function createDraftApp(
  database: D1Database,
  input: {
    developerId: string;
    developerName: string;
    appId: string;
    bundleIdentifier: string;
    name: string;
    shortDescription: string;
    description: string;
    categoryId: string;
    repositoryId: string;
    iconObjectKey: string;
  },
): Promise<void> {
  await database.batch([
    database.prepare("INSERT OR IGNORE INTO developers (id, name) VALUES (?, ?)")
      .bind(input.developerId, input.developerName),
    database.prepare(
      "INSERT INTO apps (id, bundle_identifier, name, developer_id, category_id, description, " +
      "short_description, icon_object_key, repository_id, published) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
    ).bind(
      input.appId,
      input.bundleIdentifier,
      input.name,
      input.developerId,
      input.categoryId,
      input.description,
      input.shortDescription,
      input.iconObjectKey,
      input.repositoryId,
    ),
  ]);
}

const APP_SELECT = `
  SELECT a.id, a.bundle_identifier, a.name, a.short_description, a.description,
         a.icon_object_key, a.published, a.created_at, a.updated_at,
         d.id AS developer_id, d.name AS developer_name,
         c.id AS category_id, c.name AS category_name,
         r.id AS repository_id, r.name AS repository_name,
         COUNT(DISTINCT v.id) AS release_count,
         (SELECT latest.version FROM versions AS latest WHERE latest.app_id = a.id
          ORDER BY latest.created_at DESC LIMIT 1) AS latest_version
  FROM apps AS a
  JOIN developers AS d ON d.id = a.developer_id
  JOIN categories AS c ON c.id = a.category_id
  JOIN repositories AS r ON r.id = a.repository_id
  LEFT JOIN versions AS v ON v.app_id = a.id
`;

interface AdminAppRow {
  id: unknown; bundle_identifier: unknown; name: unknown; short_description: unknown;
  description: unknown; developer_name: unknown; developer_id: unknown; category_id: unknown;
  category_name: unknown; repository_id: unknown; repository_name: unknown; icon_object_key: unknown;
  published: unknown; release_count: unknown; latest_version: unknown; created_at: unknown; updated_at: unknown;
}

function mapApp(row: AdminAppRow): AdminAppRecord {
  return {
    id: String(row.id),
    bundleIdentifier: String(row.bundle_identifier),
    name: String(row.name),
    shortDescription: String(row.short_description),
    description: String(row.description),
    developer: String(row.developer_name),
    developerId: String(row.developer_id),
    categoryId: String(row.category_id),
    category: String(row.category_name),
    repositoryId: String(row.repository_id),
    repository: String(row.repository_name),
    published: Number(row.published) === 1,
    releaseCount: Number(row.release_count),
    latestVersion: typeof row.latest_version === "string" ? row.latest_version : null,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export async function listAdminApps(database: D1Database, query = ""): Promise<AdminAppRecord[]> {
  const filter = query ? "WHERE a.deleted_at IS NULL AND (a.name LIKE ? ESCAPE '\\' OR a.bundle_identifier LIKE ? ESCAPE '\\')" :
    "WHERE a.deleted_at IS NULL";
  const value = "%" + query.replace(/[\\%_]/gu, "\\$&") + "%";
  const rows = await database.prepare(
    APP_SELECT + filter + " GROUP BY a.id ORDER BY a.updated_at DESC, a.id ASC LIMIT 200",
  ).bind(...(query ? [value, value] : [])).all<AdminAppRow>();
  return (rows.results ?? []).map(mapApp);
}

export async function findAdminApp(database: D1Database, id: string): Promise<AdminAppRecord | null> {
  const row = await database.prepare(APP_SELECT + " WHERE a.id = ? AND a.deleted_at IS NULL GROUP BY a.id LIMIT 1")
    .bind(id).first<AdminAppRow>();
  return row ? mapApp(row) : null;
}

export async function updateDraftApp(
  database: D1Database,
  input: {
    appId: string;
    developerId: string;
    developerName: string;
    name: string;
    shortDescription: string;
    description: string;
    categoryId: string;
    repositoryId: string;
  },
): Promise<number> {
  const result = await database.batch([
    database.prepare("INSERT OR IGNORE INTO developers (id, name) VALUES (?, ?)")
      .bind(input.developerId, input.developerName),
    database.prepare(
      "UPDATE apps SET name = ?, short_description = ?, description = ?, developer_id = ?, " +
      "category_id = ?, repository_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
      "WHERE id = ? AND deleted_at IS NULL",
    ).bind(
      input.name,
      input.shortDescription,
      input.description,
      input.developerId,
      input.categoryId,
      input.repositoryId,
      input.appId,
    ),
  ]);
  return result[1]?.meta.changes ?? 0;
}

export async function listAdminCategories(database: D1Database) {
  const result = await database.prepare("SELECT id, name, ordinal FROM categories ORDER BY ordinal")
    .all<{ id: string; name: string; ordinal: number }>();
  return result.results ?? [];
}

export async function listAdminRepositories(database: D1Database) {
  const result = await database.prepare(
    "SELECT id, identifier, name FROM repositories WHERE trust_level = 'official' ORDER BY name, id LIMIT 50",
  ).all<{ id: string; identifier: string; name: string }>();
  return result.results ?? [];
}

export async function listRecentAudit(database: D1Database) {
  const result = await database.prepare(
    "SELECT id, actor_subject AS actor, action, resource_type AS resourceType, resource_id AS resourceId, created_at AS createdAt " +
    "FROM audit_logs ORDER BY created_at DESC, id DESC LIMIT 20",
  ).all<{ id: string; actor: string; action: string; resourceType: string; resourceId: string | null; createdAt: string }>();
  return result.results ?? [];
}
