import {
  APP_CATEGORIES,
  compareSemanticVersions,
  isSemanticVersion,
} from "@dreyzestore/shared";
import { validateRepository } from "@dreyzestore/shared/repository-validator";
import type {
  AppVersion,
  Category,
  FeaturedSection,
  RepositoryManifest,
  RepositoryVersion,
  Screenshot,
  StoreApp,
  StoreAppSummary,
  UpdateAvailable,
} from "@dreyzestore/shared";
import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";
import { createCursor, parseCursor } from "../pagination.js";
import {
  getOfficialRepository,
  getPublishedAppById,
  listCategories,
  listFeaturedApps,
  listPublishedApps,
  listPublishedAppsByBundles,
  listPublishedVersions,
  listScreenshots,
  type AppRow,
  type AppSort,
  type PublicAppQuery,
  type ScreenshotRow,
  type VersionRow,
} from "../repositories/catalogRepository.js";

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const BUNDLE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/;
const CATEGORY_ID_PATTERN = /^[a-z][a-z0-9-]{0,79}$/;
const MINIMUM_OS_PATTERN = /^[0-9]{1,3}(?:\.[0-9]{1,3}){1,2}$/;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const OBJECT_KEY_SEGMENT_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const VERSION_BATCH_SIZE = 80;
type ObjectKeyPrefix = "icons" | "screenshots" | "packages";

interface InternalVersion {
  api: AppVersion;
  channel: "stable" | "beta";
  publishedAt: string;
}

interface PageOptions {
  page: number;
  pageSize: number;
  cursor?: string;
}

export interface ListAppsOptions extends PageOptions {
  categoryId?: string;
  repositoryIdentifier?: string;
  searchQuery?: string;
  sort: AppSort;
}

export interface AppPage {
  items: StoreAppSummary[];
  page?: number;
  pageSize: number;
  hasMore: boolean;
  nextCursor?: string;
}

export interface UpdateRequestItem {
  bundleIdentifier: string;
  installedVersion: string;
}

function invalidStoredData(): ApiError {
  return new ApiError(500, "catalog_data_invalid", "Catalog metadata could not be served.");
}

function requiredString(value: unknown, maxLength: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw invalidStoredData();
  }
  return value;
}

function requiredId(value: unknown): string {
  const id = requiredString(value, 128);
  if (!ID_PATTERN.test(id)) throw invalidStoredData();
  return id;
}

function requiredBundleIdentifier(value: unknown): string {
  const identifier = requiredString(value, 255);
  if (!BUNDLE_PATTERN.test(identifier)) throw invalidStoredData();
  return identifier;
}

function requiredTimestamp(value: unknown): string {
  const timestamp = requiredString(value, 40);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(timestamp)) {
    throw invalidStoredData();
  }
  const milliseconds = Date.parse(timestamp);
  if (!Number.isFinite(milliseconds)) throw invalidStoredData();
  return new Date(milliseconds).toISOString();
}

function requiredPositiveInteger(value: unknown, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1 || value > maximum) {
    throw invalidStoredData();
  }
  return value;
}

function configuredAssetBase(value: string): URL {
  let base: URL;
  try {
    base = new URL(value);
  } catch {
    throw new ApiError(500, "service_configuration_error", "Catalog assets are not configured.");
  }
  if (base.protocol !== "https:" || !base.hostname || base.username || base.password || base.search || base.hash) {
    throw new ApiError(500, "service_configuration_error", "Catalog assets are not configured.");
  }
  if (!base.pathname.endsWith("/")) base.pathname += "/";
  return base;
}

function publicObjectURL(base: URL, value: unknown, expectedPrefix: ObjectKeyPrefix): string {
  const key = requiredString(value, 512);
  const segments = key.split("/");
  if (
    segments.length < 2 ||
    segments[0] !== expectedPrefix ||
    segments.some((segment) =>
      segment.length === 0 || segment === "." || segment === ".." || !OBJECT_KEY_SEGMENT_PATTERN.test(segment),
    )
  ) {
    throw invalidStoredData();
  }
  const encoded = segments.map((segment) => encodeURIComponent(segment)).join("/");
  return new URL(encoded, base).href;
}

function isAppCategory(value: string): value is (typeof APP_CATEGORIES)[number] {
  return (APP_CATEGORIES as readonly string[]).includes(value);
}

function categoryIdForName(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function isHttpsURL(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 2048) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && Boolean(url.hostname) && !url.username && !url.password;
  } catch {
    return false;
  }
}

function mapVersion(row: VersionRow, assetBase: URL): InternalVersion {
  const version = requiredString(row.version, 100);
  if (!isSemanticVersion(version)) throw invalidStoredData();
  const build = requiredString(row.build, 64);
  if (!/^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(build)) throw invalidStoredData();
  const minimumOSVersion = requiredString(row.minimum_ios, 32);
  if (!MINIMUM_OS_PATTERN.test(minimumOSVersion)) throw invalidStoredData();
  if (typeof row.sha256 !== "string" || !SHA256_PATTERN.test(row.sha256)) throw invalidStoredData();
  const size = requiredPositiveInteger(row.size, 4_294_967_296);
  const channel = row.channel;
  if (channel !== "stable" && channel !== "beta") throw invalidStoredData();
  const publishedAt = requiredTimestamp(row.published_at);

  return {
    api: {
      id: requiredId(row.id),
      version,
      build,
      versionDate: publishedAt,
      minimumOSVersion,
      downloadURL: publicObjectURL(assetBase, row.ipa_object_key, "packages"),
      sha256: row.sha256,
      size,
      releaseNotes: (() => {
        if (typeof row.release_notes !== "string" || row.release_notes.length > 10_000) {
          throw invalidStoredData();
        }
        return row.release_notes;
      })(),
      channel,
    },
    channel,
    publishedAt,
  };
}

function mapAppSummary(row: AppRow, latest: InternalVersion, assetBase: URL): StoreAppSummary {
  const categoryName = requiredString(row.category_name, 80);
  const categoryId = requiredString(row.category_id, 80);
  if (
    !isAppCategory(categoryName) ||
    !CATEGORY_ID_PATTERN.test(categoryId) ||
    categoryId !== categoryIdForName(categoryName)
  ) {
    throw invalidStoredData();
  }
  const repositoryIdentifier = requiredString(row.repository_identifier, 255);
  if (!BUNDLE_PATTERN.test(repositoryIdentifier)) throw invalidStoredData();
  const website = row.developer_website_url;
  const developer = {
    id: requiredId(row.developer_id),
    name: requiredString(row.developer_name, 200),
    ...(isHttpsURL(website) ? { websiteURL: website } : {}),
  };

  return {
    id: requiredId(row.app_id),
    bundleIdentifier: requiredBundleIdentifier(row.bundle_identifier),
    name: requiredString(row.app_name, 160),
    developer,
    category: {
      id: categoryId,
      name: categoryName,
    },
    iconURL: publicObjectURL(assetBase, row.icon_object_key, "icons"),
    currentVersion: latest.api,
    repositoryIdentifier,
    repositoryName: requiredString(row.repository_name, 120),
  };
}

function mapScreenshot(row: ScreenshotRow, assetBase: URL): Screenshot {
  const width = requiredPositiveInteger(row.width, 16_384);
  const height = requiredPositiveInteger(row.height, 16_384);
  return {
    url: publicObjectURL(assetBase, row.object_key, "screenshots"),
    width,
    height,
    alt: requiredString(row.alt_text, 240),
  };
}

function sortBySemanticVersion(versions: InternalVersion[]): InternalVersion[] {
  return [...versions].sort((left, right) => {
    const precedence = compareSemanticVersions(right.api.version, left.api.version);
    if (precedence !== 0) return precedence;
    return right.publishedAt.localeCompare(left.publishedAt) || right.api.id.localeCompare(left.api.id);
  });
}

function latestVersion(versions: InternalVersion[], stableOnly: boolean): InternalVersion | undefined {
  const candidates = stableOnly ? versions.filter((version) => version.channel === "stable") : versions;
  return sortBySemanticVersion(candidates)[0];
}

function ftsExpression(query: string): string | null {
  const terms = query.normalize("NFKC").match(/[\p{L}\p{N}]+/gu) ?? [];
  if (terms.length === 0) return null;
  if (terms.length > 12) throw new ApiError(400, "invalid_query", "Search query contains too many terms.");
  return terms.map((term) => `"${term}"*`).join(" AND ");
}

function rowCursorKey(row: AppRow, sort: AppSort): string {
  if (sort === "name") return requiredString(row.app_name, 160);
  return requiredTimestamp(sort === "updated" ? row.app_updated_at : row.app_created_at);
}

async function loadVersions(
  environment: WorkerEnvironment,
  appIds: string[],
  assetBase: URL,
  stableOnly = false,
): Promise<Map<string, InternalVersion[]>> {
  const grouped = new Map<string, InternalVersion[]>();
  for (let offset = 0; offset < appIds.length; offset += VERSION_BATCH_SIZE) {
    const batch = appIds.slice(offset, offset + VERSION_BATCH_SIZE);
    const rows = await listPublishedVersions(environment.DB, batch, stableOnly);
    for (const row of rows) {
      const appId = requiredId(row.app_id);
      const versions = grouped.get(appId) ?? [];
      versions.push(mapVersion(row, assetBase));
      grouped.set(appId, versions);
    }
  }
  return grouped;
}

function requireLatest(versions: InternalVersion[]): InternalVersion {
  const selected = latestVersion(versions, true) ?? latestVersion(versions, false);
  if (!selected) throw invalidStoredData();
  return selected;
}

function makePageMeta(
  options: PageOptions,
  hasMore: boolean,
  nextCursor?: string,
): Omit<AppPage, "items"> {
  return {
    ...(options.cursor === undefined ? { page: options.page } : {}),
    pageSize: options.pageSize,
    hasMore,
    ...(nextCursor ? { nextCursor } : {}),
  };
}

async function listAppsPage(
  environment: WorkerEnvironment,
  options: ListAppsOptions,
): Promise<AppPage> {
  const searchQuery = options.searchQuery?.normalize("NFKC").trim();
  const filterKey = JSON.stringify({
    categoryId: options.categoryId ?? null,
    repositoryIdentifier: options.repositoryIdentifier ?? null,
    searchQuery: searchQuery ?? null,
    sort: options.sort,
  });
  const after = options.cursor
    ? await parseCursor(options.cursor, options.sort, filterKey)
    : undefined;
  const searchExpression = searchQuery ? ftsExpression(searchQuery) : undefined;
  if (options.searchQuery !== undefined && !searchExpression) {
    return { ...makePageMeta(options, false), items: [] };
  }
  const query: PublicAppQuery = {
    sort: options.sort,
    limit: options.pageSize + 1,
    offset: after ? 0 : (options.page - 1) * options.pageSize,
    ...(after ? { after } : {}),
    ...(options.categoryId ? { categoryId: options.categoryId } : {}),
    ...(options.repositoryIdentifier ? { repositoryIdentifier: options.repositoryIdentifier } : {}),
    ...(searchExpression ? { searchExpression } : {}),
  };
  const rows = await listPublishedApps(environment.DB, query);
  const hasMore = rows.length > options.pageSize;
  const visibleRows = rows.slice(0, options.pageSize);
  const appIds = visibleRows.map((row) => requiredId(row.app_id));
  const assetBase = configuredAssetBase(environment.PUBLIC_ASSETS_BASE_URL);
  const versions = await loadVersions(environment, appIds, assetBase);
  const items = visibleRows.map((row) => {
    const id = requiredId(row.app_id);
    return mapAppSummary(row, requireLatest(versions.get(id) ?? []), assetBase);
  });

  const cursorOptions: PageOptions = {
    page: options.page,
    pageSize: options.pageSize,
    ...(options.cursor ? { cursor: options.cursor } : {}),
  };
  const base = makePageMeta(cursorOptions, hasMore);
  const lastRow = visibleRows.at(-1);
  const nextCursor = hasMore && lastRow
    ? await createCursor(options.sort, filterKey, {
      id: requiredId(lastRow.app_id),
      key: rowCursorKey(lastRow, options.sort),
    })
    : undefined;
  return { ...base, items, ...(nextCursor ? { nextCursor } : {}) };
}

export async function getAppsPage(
  environment: WorkerEnvironment,
  options: ListAppsOptions,
): Promise<AppPage> {
  return listAppsPage(environment, options);
}

export async function getAppDetails(environment: WorkerEnvironment, appId: string): Promise<StoreApp | null> {
  const row = await getPublishedAppById(environment.DB, appId);
  if (!row) return null;
  const id = requiredId(row.app_id);
  const assetBase = configuredAssetBase(environment.PUBLIC_ASSETS_BASE_URL);
  const [versionGroups, screenshotRows] = await Promise.all([
    loadVersions(environment, [id], assetBase),
    listScreenshots(environment.DB, [id]),
  ]);
  const versions = versionGroups.get(id) ?? [];
  const summary = mapAppSummary(row, requireLatest(versions), assetBase);
  return {
    ...summary,
    description: requiredString(row.app_description, 20_000),
    screenshots: screenshotRows.map((screenshot) => mapScreenshot(screenshot, assetBase)),
  };
}

export async function getAppVersions(environment: WorkerEnvironment, appId: string): Promise<AppVersion[] | null> {
  const row = await getPublishedAppById(environment.DB, appId);
  if (!row) return null;
  const assetBase = configuredAssetBase(environment.PUBLIC_ASSETS_BASE_URL);
  const versions = await loadVersions(environment, [requiredId(row.app_id)], assetBase);
  return (versions.get(requiredId(row.app_id)) ?? [])
    .sort((left, right) => right.publishedAt.localeCompare(left.publishedAt) || right.api.id.localeCompare(left.api.id))
    .map((version) => version.api);
}

export async function getCategories(environment: WorkerEnvironment): Promise<Category[]> {
  const rows = await listCategories(environment.DB);
  return rows.map((row) => {
    const name = requiredString(row.name, 80);
    const id = requiredString(row.id, 80);
    if (!isAppCategory(name) || !CATEGORY_ID_PATTERN.test(id) || id !== categoryIdForName(name)) {
      throw invalidStoredData();
    }
    if (typeof row.app_count !== "number" || !Number.isSafeInteger(row.app_count) || row.app_count < 0) {
      throw invalidStoredData();
    }
    return { id, name, appCount: row.app_count };
  });
}

const FEATURED_TITLES: Record<string, string> = {
  hero: "Featured",
  "editors-picks": "Editor’s Picks",
  "new-releases": "New Releases",
  "recently-updated": "Recently Updated",
  popular: "Popular",
};
const FEATURED_ORDER = ["hero", "editors-picks", "new-releases", "recently-updated", "popular"];

export async function getFeatured(environment: WorkerEnvironment): Promise<FeaturedSection[]> {
  const now = new Date().toISOString();
  const rows = await listFeaturedApps(environment.DB, now);
  const grouped = new Map<string, AppRow[]>();
  for (const row of rows) {
    const key = requiredString(row.section_key, 80);
    if (!Object.hasOwn(FEATURED_TITLES, key)) throw invalidStoredData();
    const section = grouped.get(key) ?? [];
    section.push(row);
    grouped.set(key, section);
  }
  const assetBase = configuredAssetBase(environment.PUBLIC_ASSETS_BASE_URL);
  const allRows = [...grouped.values()].flat();
  const versions = await loadVersions(environment, allRows.map((row) => requiredId(row.app_id)), assetBase);
  return FEATURED_ORDER.flatMap((key) => {
    const sectionRows = grouped.get(key);
    if (!sectionRows?.length) return [];
    return [{
      key,
      title: FEATURED_TITLES[key]!,
      items: sectionRows.map((row) => {
        const id = requiredId(row.app_id);
        return mapAppSummary(row, requireLatest(versions.get(id) ?? []), assetBase);
      }),
    }];
  });
}

export async function getUpdates(
  environment: WorkerEnvironment,
  requests: UpdateRequestItem[],
): Promise<UpdateAvailable[]> {
  if (requests.length === 0) return [];
  const rows = await listPublishedAppsByBundles(environment.DB, requests.map((item) => item.bundleIdentifier));
  const assetBase = configuredAssetBase(environment.PUBLIC_ASSETS_BASE_URL);
  const appIds = rows.map((row) => requiredId(row.app_id));
  const versions = await loadVersions(environment, appIds, assetBase, true);
  const installed = new Map(requests.map((item) => [item.bundleIdentifier, item.installedVersion]));
  const updates: UpdateAvailable[] = [];

  for (const row of rows) {
    const bundleIdentifier = requiredBundleIdentifier(row.bundle_identifier);
    const installedVersion = installed.get(bundleIdentifier);
    if (!installedVersion) continue;
    const candidates = versions.get(requiredId(row.app_id)) ?? [];
    const latest = latestVersion(candidates, true);
    if (!latest || compareSemanticVersions(latest.api.version, installedVersion) <= 0) continue;
    updates.push({
      app: mapAppSummary(row, latest, assetBase),
      installedVersion,
      latestVersion: latest.api,
    });
  }

  return updates.sort((left, right) => left.app.name.localeCompare(right.app.name));
}

function mapRepositoryVersion(version: InternalVersion): RepositoryVersion {
  const { api } = version;
  return {
    version: api.version,
    build: api.build,
    versionDate: api.versionDate,
    minimumOSVersion: api.minimumOSVersion,
    downloadURL: api.downloadURL,
    sha256: api.sha256,
    size: api.size,
    releaseNotes: api.releaseNotes,
    channel: api.channel,
  };
}

export async function getRepositoryManifest(environment: WorkerEnvironment): Promise<RepositoryManifest> {
  const repository = await getOfficialRepository(environment.DB);
  if (!repository) throw new ApiError(503, "catalog_unavailable", "The official repository is not configured.");

  const repositoryId = requiredId(repository.id);
  const repositoryIdentifier = requiredString(repository.identifier, 255);
  if (!BUNDLE_PATTERN.test(repositoryIdentifier)) throw invalidStoredData();
  const repositoryName = requiredString(repository.name, 120);
  const repositoryDescription = requiredString(repository.description, 4000);
  const repositoryUpdatedAt = requiredTimestamp(repository.updated_at);
  const assetBase = configuredAssetBase(environment.PUBLIC_ASSETS_BASE_URL);
  const appRows = await listPublishedApps(environment.DB, {
    repositoryId,
    sort: "name",
    limit: 1001,
    offset: 0,
  });
  if (appRows.length > 1000) throw invalidStoredData();

  const appIds = appRows.map((row) => requiredId(row.app_id));
  const versionGroups = new Map<string, InternalVersion[]>();
  const screenshotGroups = new Map<string, Screenshot[]>();
  for (let offset = 0; offset < appIds.length; offset += VERSION_BATCH_SIZE) {
    const batch = appIds.slice(offset, offset + VERSION_BATCH_SIZE);
    const [versionRows, screenshotRows] = await Promise.all([
      listPublishedVersions(environment.DB, batch),
      listScreenshots(environment.DB, batch),
    ]);
    for (const versionRow of versionRows) {
      const appId = requiredId(versionRow.app_id);
      const existing = versionGroups.get(appId) ?? [];
      existing.push(mapVersion(versionRow, assetBase));
      versionGroups.set(appId, existing);
    }
    for (const screenshotRow of screenshotRows) {
      const appId = requiredId(screenshotRow.app_id);
      const existing = screenshotGroups.get(appId) ?? [];
      existing.push(mapScreenshot(screenshotRow, assetBase));
      screenshotGroups.set(appId, existing);
    }
  }

  const generatedAtCandidates = [repositoryUpdatedAt];
  const apps = appRows.map((row) => {
    const id = requiredId(row.app_id);
    const category = requiredString(row.category_name, 80);
    if (!isAppCategory(category)) throw invalidStoredData();
    const publishedVersions = versionGroups.get(id) ?? [];
    if (publishedVersions.length === 0 || publishedVersions.length > 50) throw invalidStoredData();
    const appUpdatedAt = requiredTimestamp(row.app_updated_at);
    generatedAtCandidates.push(appUpdatedAt, ...publishedVersions.map((version) => version.publishedAt));

    return {
      bundleIdentifier: requiredBundleIdentifier(row.bundle_identifier),
      name: requiredString(row.app_name, 160),
      developer: requiredString(row.developer_name, 200),
      category,
      description: requiredString(row.app_description, 20_000),
      icon: publicObjectURL(assetBase, row.icon_object_key, "icons"),
      screenshots: screenshotGroups.get(id) ?? [],
      versions: [...publishedVersions]
        .sort((left, right) => right.publishedAt.localeCompare(left.publishedAt))
        .map(mapRepositoryVersion),
    };
  });

  const generatedAt = generatedAtCandidates
    .map((value) => new Date(value).getTime())
    .reduce((latest, value) => Math.max(latest, value), 0);
  const manifest: RepositoryManifest = {
    schemaVersion: 1,
    name: repositoryName,
    identifier: repositoryIdentifier,
    description: repositoryDescription,
    icon: publicObjectURL(assetBase, repository.icon_object_key, "icons"),
    generatedAt: new Date(generatedAt).toISOString(),
    apps,
  };

  if (!validateRepository(manifest).valid) throw invalidStoredData();
  return manifest;
}

export function buildSearchExpression(query: string): string | null {
  return ftsExpression(query);
}

export function assertSearchQuery(query: string): string {
  const trimmed = query.normalize("NFKC").trim();
  if ([...trimmed].length > 100) {
    throw new ApiError(400, "invalid_query", "Search query must be 100 characters or fewer.");
  }
  return trimmed;
}
