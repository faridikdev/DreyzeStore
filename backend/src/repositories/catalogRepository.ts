export type AppSort = "name" | "updated" | "newest";

export interface PublicAppQuery {
  categoryId?: string;
  repositoryIdentifier?: string;
  repositoryId?: string;
  searchExpression?: string;
  sort: AppSort;
  limit: number;
  offset: number;
  after?: { key: string; id: string };
}

export interface AppRow {
  app_id: unknown;
  bundle_identifier: unknown;
  app_name: unknown;
  app_description: unknown;
  app_short_description: unknown;
  icon_object_key: unknown;
  app_updated_at: unknown;
  app_created_at: unknown;
  developer_id: unknown;
  developer_name: unknown;
  developer_website_url: unknown;
  category_id: unknown;
  category_name: unknown;
  repository_id: unknown;
  repository_identifier: unknown;
  repository_name: unknown;
}

export interface VersionRow {
  id: unknown;
  app_id: unknown;
  version: unknown;
  build: unknown;
  minimum_ios: unknown;
  ipa_object_key: unknown;
  sha256: unknown;
  size: unknown;
  release_notes: unknown;
  channel: unknown;
  published_at: unknown;
}

export interface ScreenshotRow {
  id: unknown;
  app_id: unknown;
  object_key: unknown;
  width: unknown;
  height: unknown;
  alt_text: unknown;
  ordinal: unknown;
}

export interface CategoryRow {
  id: unknown;
  name: unknown;
  app_count: unknown;
}

export interface FeaturedAppRow extends AppRow {
  section_key: unknown;
  ordinal: unknown;
}

export interface OfficialRepositoryRow {
  id: unknown;
  identifier: unknown;
  name: unknown;
  description: unknown;
  icon_object_key: unknown;
  updated_at: unknown;
}

const APP_COLUMNS = `
  a.id AS app_id,
  a.bundle_identifier,
  a.name AS app_name,
  a.description AS app_description,
  a.short_description AS app_short_description,
  a.icon_object_key,
  a.updated_at AS app_updated_at,
  a.created_at AS app_created_at,
  d.id AS developer_id,
  d.name AS developer_name,
  d.website_url AS developer_website_url,
  c.id AS category_id,
  c.name AS category_name,
  r.id AS repository_id,
  r.identifier AS repository_identifier,
  r.name AS repository_name`;

const APP_FROM = `
  FROM apps AS a
  JOIN developers AS d ON d.id = a.developer_id
  JOIN categories AS c ON c.id = a.category_id
  JOIN repositories AS r ON r.id = a.repository_id`;

const PUBLIC_APP_CONDITION = `
  a.published = 1
  AND a.deleted_at IS NULL
  AND EXISTS (
    SELECT 1 FROM versions AS public_version
    WHERE public_version.app_id = a.id AND public_version.published_at IS NOT NULL
  )`;

const SORT_SQL: Record<AppSort, string> = {
  name: "a.name COLLATE NOCASE ASC, a.id ASC",
  updated: "a.updated_at DESC, a.id ASC",
  newest: "a.created_at DESC, a.id ASC",
};

async function all<T>(database: D1Database, sql: string, values: unknown[] = []): Promise<T[]> {
  const result = await database.prepare(sql).bind(...values).all<T>();
  return result.results ?? [];
}

export async function listPublishedApps(
  database: D1Database,
  query: PublicAppQuery,
): Promise<AppRow[]> {
  const conditions = [PUBLIC_APP_CONDITION];
  const values: unknown[] = [];

  if (query.categoryId !== undefined) {
    conditions.push("a.category_id = ?");
    values.push(query.categoryId);
  }
  if (query.repositoryIdentifier !== undefined) {
    conditions.push("r.identifier = ?");
    values.push(query.repositoryIdentifier);
  }
  if (query.repositoryId !== undefined) {
    conditions.push("r.id = ?");
    values.push(query.repositoryId);
  }
  if (query.searchExpression !== undefined) {
    conditions.push(`EXISTS (
      SELECT 1 FROM app_search
      WHERE app_search.app_id = a.id AND app_search MATCH ?
    )`);
    values.push(query.searchExpression);
  }

  if (query.after !== undefined) {
    if (query.sort === "name") {
      conditions.push(
        "(a.name COLLATE NOCASE > ? OR (a.name COLLATE NOCASE = ? AND a.id > ?))",
      );
      values.push(query.after.key, query.after.key, query.after.id);
    } else if (query.sort === "updated") {
      conditions.push("(a.updated_at < ? OR (a.updated_at = ? AND a.id > ?))");
      values.push(query.after.key, query.after.key, query.after.id);
    } else {
      conditions.push("(a.created_at < ? OR (a.created_at = ? AND a.id > ?))");
      values.push(query.after.key, query.after.key, query.after.id);
    }
  }

  values.push(query.limit, query.offset);
  return all<AppRow>(
    database,
    `SELECT ${APP_COLUMNS}
     ${APP_FROM}
     WHERE ${conditions.join(" AND ")}
     ORDER BY ${SORT_SQL[query.sort]}
     LIMIT ? OFFSET ?`,
    values,
  );
}

export async function getPublishedAppById(database: D1Database, appId: string): Promise<AppRow | null> {
  return database
    .prepare(`SELECT ${APP_COLUMNS} ${APP_FROM} WHERE a.id = ? AND ${PUBLIC_APP_CONDITION} LIMIT 1`)
    .bind(appId)
    .first<AppRow>();
}

export async function listPublishedAppsByBundles(
  database: D1Database,
  bundleIdentifiers: string[],
): Promise<AppRow[]> {
  if (bundleIdentifiers.length === 0) return [];
  const placeholders = bundleIdentifiers.map(() => "?").join(", ");
  return all<AppRow>(
    database,
    `SELECT ${APP_COLUMNS}
     ${APP_FROM}
     WHERE ${PUBLIC_APP_CONDITION}
       AND a.bundle_identifier IN (${placeholders})
     ORDER BY a.id ASC`,
    bundleIdentifiers,
  );
}

export async function listPublishedVersions(
  database: D1Database,
  appIds: string[],
  stableOnly = false,
): Promise<VersionRow[]> {
  if (appIds.length === 0) return [];
  const placeholders = appIds.map(() => "?").join(", ");
  const stableCondition = stableOnly ? "AND channel = 'stable'" : "";
  return all<VersionRow>(
    database,
    `SELECT id, app_id, version, build, minimum_ios, ipa_object_key, sha256,
            size, release_notes, channel, published_at
     FROM versions
     WHERE published_at IS NOT NULL ${stableCondition}
       AND app_id IN (${placeholders})
     ORDER BY app_id ASC, published_at DESC, id DESC`,
    appIds,
  );
}

export async function listScreenshots(database: D1Database, appIds: string[]): Promise<ScreenshotRow[]> {
  if (appIds.length === 0) return [];
  const placeholders = appIds.map(() => "?").join(", ");
  return all<ScreenshotRow>(
    database,
    `SELECT id, app_id, object_key, width, height, alt_text, ordinal
     FROM screenshots
     WHERE app_id IN (${placeholders})
     ORDER BY app_id ASC, ordinal ASC, id ASC`,
    appIds,
  );
}

export async function listCategories(database: D1Database): Promise<CategoryRow[]> {
  return all<CategoryRow>(
    database,
    `SELECT c.id, c.name, COUNT(a.id) AS app_count
     FROM categories AS c
     LEFT JOIN apps AS a
       ON a.category_id = c.id
      AND a.published = 1
      AND a.deleted_at IS NULL
      AND EXISTS (
        SELECT 1 FROM versions AS public_version
        WHERE public_version.app_id = a.id AND public_version.published_at IS NOT NULL
      )
     GROUP BY c.id, c.name, c.ordinal
     ORDER BY c.ordinal ASC, c.id ASC`,
  );
}

export async function listFeaturedApps(database: D1Database, now: string): Promise<FeaturedAppRow[]> {
  return all<FeaturedAppRow>(
    database,
    `SELECT f.section_key, f.ordinal, ${APP_COLUMNS}
     FROM featured AS f
     JOIN apps AS a ON a.id = f.app_id
     JOIN developers AS d ON d.id = a.developer_id
     JOIN categories AS c ON c.id = a.category_id
     JOIN repositories AS r ON r.id = a.repository_id
     WHERE (f.starts_at IS NULL OR f.starts_at <= ?)
       AND (f.ends_at IS NULL OR f.ends_at > ?)
       AND ${PUBLIC_APP_CONDITION}
     ORDER BY f.section_key ASC, f.ordinal ASC, a.id ASC
     LIMIT 100`,
    [now, now],
  );
}

export async function getOfficialRepository(database: D1Database): Promise<OfficialRepositoryRow | null> {
  return database
    .prepare(`SELECT id, identifier, name, description, icon_object_key, updated_at
              FROM repositories WHERE trust_level = 'official' LIMIT 1`)
    .first<OfficialRepositoryRow>();
}
