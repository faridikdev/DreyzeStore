import { APP_CATEGORIES, isSemanticVersion } from "@dreyzestore/shared";
import type { Hono } from "hono";
import type { WorkerEnvironment } from "../env.js";
import { ApiError, type ApiContext, type ApiVariables, validationError } from "../errors.js";
import { cachedJsonResponse, noStoreJsonResponse } from "../http/jsonResponse.js";
import { parsePagination, readQuery } from "../queryParameters.js";
import type { AppSort } from "../repositories/catalogRepository.js";
import {
  assertSearchQuery,
  getAppDetails,
  getAppVersions,
  getAppsPage,
  getCategories,
  getFeatured,
  getRepositoryManifest,
  getUpdates,
  type UpdateRequestItem,
} from "../services/catalogService.js";

const APP_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const BUNDLE_IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/;
const REPOSITORY_IDENTIFIER_PATTERN = BUNDLE_IDENTIFIER_PATTERN;
const CATEGORY_IDS = new Set(APP_CATEGORIES.map((name) => name.toLowerCase().replace(/[^a-z0-9]+/g, "-")));
const MAX_UPDATE_ITEMS = 25;
const MAX_UPDATE_QUERY_LENGTH = 2500;

function parseSort(value: string | undefined): AppSort {
  if (value === undefined || value === "name") return "name";
  if (value === "updated" || value === "newest") return value;
  throw validationError("sort", "must be one of: name, updated, newest.");
}

function parseCategory(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (!CATEGORY_IDS.has(value)) throw validationError("category", "is not a supported category identifier.");
  return value;
}

function parseRepository(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (value.length > 255 || !REPOSITORY_IDENTIFIER_PATTERN.test(value)) {
    throw validationError("repository", "must be a valid reverse-DNS repository identifier.");
  }
  return value;
}

function parseAppId(value: string): string {
  if (!APP_ID_PATTERN.test(value)) throw validationError("id", "must be a valid application identifier.");
  return value;
}

function pageEnvelope(page: Awaited<ReturnType<typeof getAppsPage>>) {
  return {
    data: page.items,
    meta: {
      ...(page.page === undefined ? {} : { page: page.page }),
      pageSize: page.pageSize,
      hasMore: page.hasMore,
      ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
    },
  };
}

function parseUpdateRequests(raw: string | undefined): UpdateRequestItem[] {
  if (raw === undefined || raw.length === 0) throw validationError("apps", "is required and must be a JSON array.");
  if (raw.length > MAX_UPDATE_QUERY_LENGTH) {
    throw new ApiError(413, "request_too_large", "The update request is too large.");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw validationError("apps", "must contain valid JSON.");
  }
  if (!Array.isArray(parsed)) throw validationError("apps", "must be a JSON array.");
  if (parsed.length > MAX_UPDATE_ITEMS) {
    throw new ApiError(413, "request_too_large", `A maximum of ${MAX_UPDATE_ITEMS} applications is allowed.`);
  }

  const seen = new Set<string>();
  return parsed.map((item: unknown, index: number) => {
    if (typeof item !== "object" || item === null || Array.isArray(item)) {
      throw validationError(`apps[${index}]`, "must be an object.");
    }
    const record = item as Record<string, unknown>;
    const keys = Object.keys(record).sort();
    if (keys.join(",") !== "bundleIdentifier,installedVersion") {
      throw validationError(`apps[${index}]`, "must contain only bundleIdentifier and installedVersion.");
    }
    const bundleIdentifier = record["bundleIdentifier"];
    const installedVersion = record["installedVersion"];
    if (
      typeof bundleIdentifier !== "string" ||
      bundleIdentifier.length > 255 ||
      !BUNDLE_IDENTIFIER_PATTERN.test(bundleIdentifier)
    ) {
      throw validationError(`apps[${index}].bundleIdentifier`, "must be a valid bundle identifier.");
    }
    if (typeof installedVersion !== "string" || installedVersion.length > 100 || !isSemanticVersion(installedVersion)) {
      throw validationError(`apps[${index}].installedVersion`, "must be a valid semantic version.");
    }
    if (seen.has(bundleIdentifier)) throw validationError("apps", "must not contain duplicate bundle identifiers.");
    seen.add(bundleIdentifier);
    return { bundleIdentifier, installedVersion };
  });
}

export function catalogRoutes(routes: Hono<{
  Bindings: WorkerEnvironment;
  Variables: ApiVariables;
}>): void {
  routes.get("/apps", async (context) => {
    const query = readQuery(context.req.url, ["category", "repository", "sort", "page", "limit", "cursor"]);
    const pagination = parsePagination(query);
    const page = await getAppsPage(context.env, {
      ...pagination,
      categoryId: parseCategory(query.get("category")),
      repositoryIdentifier: parseRepository(query.get("repository")),
      sort: parseSort(query.get("sort")),
    });
    return cachedJsonResponse(context as ApiContext, pageEnvelope(page), {
      maxAgeSeconds: 60,
      sharedMaxAgeSeconds: 180,
      staleWhileRevalidateSeconds: 60,
    });
  });

  routes.get("/apps/:id/versions", async (context) => {
    readQuery(context.req.url, []);
    const id = parseAppId(context.req.param("id"));
    const versions = await getAppVersions(context.env, id);
    if (!versions) throw new ApiError(404, "not_found", "The requested resource was not found.");
    return cachedJsonResponse(context as ApiContext, { data: versions }, {
      maxAgeSeconds: 120,
      sharedMaxAgeSeconds: 300,
    });
  });

  routes.get("/apps/:id", async (context) => {
    readQuery(context.req.url, []);
    const id = parseAppId(context.req.param("id"));
    const app = await getAppDetails(context.env, id);
    if (!app) throw new ApiError(404, "not_found", "The requested resource was not found.");
    return cachedJsonResponse(context as ApiContext, { data: app }, {
      maxAgeSeconds: 120,
      sharedMaxAgeSeconds: 300,
      staleWhileRevalidateSeconds: 60,
    });
  });

  routes.get("/categories", async (context) => {
    readQuery(context.req.url, []);
    const categories = await getCategories(context.env);
    return cachedJsonResponse(context as ApiContext, { data: categories }, {
      maxAgeSeconds: 900,
      sharedMaxAgeSeconds: 1800,
    });
  });

  routes.get("/featured", async (context) => {
    readQuery(context.req.url, []);
    const featured = await getFeatured(context.env);
    return cachedJsonResponse(context as ApiContext, { data: featured }, {
      maxAgeSeconds: 60,
      sharedMaxAgeSeconds: 180,
      staleWhileRevalidateSeconds: 60,
    });
  });

  routes.get("/search", async (context) => {
    const query = readQuery(context.req.url, ["q", "category", "repository", "sort", "page", "limit", "cursor"]);
    const pagination = parsePagination(query);
    const searchQuery = assertSearchQuery(query.get("q") ?? "");
    const page = await getAppsPage(context.env, {
      ...pagination,
      categoryId: parseCategory(query.get("category")),
      repositoryIdentifier: parseRepository(query.get("repository")),
      searchQuery,
      sort: parseSort(query.get("sort")),
    });
    return cachedJsonResponse(context as ApiContext, pageEnvelope(page), {
      maxAgeSeconds: 30,
      sharedMaxAgeSeconds: 60,
      staleWhileRevalidateSeconds: 30,
    });
  });

  routes.get("/updates", async (context) => {
    const query = readQuery(context.req.url, ["apps"]);
    const requests = parseUpdateRequests(query.get("apps"));
    const updates = await getUpdates(context.env, requests);
    return noStoreJsonResponse(context as ApiContext, { data: updates });
  });

  routes.get("/repository", async (context) => {
    readQuery(context.req.url, []);
    const manifest = await getRepositoryManifest(context.env);
    return cachedJsonResponse(context as ApiContext, manifest, {
      maxAgeSeconds: 60,
      sharedMaxAgeSeconds: 300,
      staleWhileRevalidateSeconds: 60,
    });
  });
}
