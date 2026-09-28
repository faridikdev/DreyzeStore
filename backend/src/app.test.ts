import { DatabaseSync } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { validateRepository } from "@dreyzestore/shared/repository-validator";
import type { RepositoryManifest } from "@dreyzestore/shared";
import { app } from "./app.js";
import type { WorkerEnvironment } from "./env.js";

const sourceDirectory = dirname(fileURLToPath(import.meta.url));
const migrationDirectory = resolve(sourceDirectory, "../migrations");
const seedPath = resolve(sourceDirectory, "../seeds/dev.sql");

function createEnvironment(database: DatabaseSync): WorkerEnvironment {
  const d1 = {
    prepare(query: string) {
      const statement = database.prepare(query);
      let boundValues: unknown[] = [];
      const prepared = {
        bind(...values: unknown[]) {
          boundValues = values;
          return prepared;
        },
        async all<T = Record<string, unknown>>() {
          return {
            results: statement.all(...(boundValues as never[])) as T[],
            success: true,
            meta: {},
          };
        },
        async first<T = Record<string, unknown>>() {
          return (statement.get(...(boundValues as never[])) as T | undefined) ?? null;
        },
      };
      return prepared;
    },
  } as unknown as D1Database;

  return {
    DB: d1,
    PASSWORD_KDF: {
      idFromName(name: string) { return { name }; },
      get() { return { async fetch() { throw new Error("The catalog API test must not call password authentication."); } }; },
    } as unknown as DurableObjectNamespace,
    PUBLIC_ASSETS: {} as R2Bucket,
    STAGING_ASSETS: {} as R2Bucket,
    ADMIN_ORIGINS: "http://localhost:5173",
    PUBLIC_ASSETS_BASE_URL: "https://assets.example.invalid",
  };
}

let database: DatabaseSync;
let environment: WorkerEnvironment;

beforeEach(() => {
  database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys = ON");
  for (const name of readdirSync(migrationDirectory).filter((file) => file.endsWith(".sql")).sort()) {
    database.exec(readFileSync(resolve(migrationDirectory, name), "utf8"));
  }
  database.exec(readFileSync(seedPath, "utf8"));
  environment = createEnvironment(database);
});

afterEach(() => database.close());

async function request(path: string, headers?: HeadersInit): Promise<Response> {
  return app.request(path, { headers }, environment);
}

function updatesURL(values: Array<{ bundleIdentifier: string; installedVersion: string }>): string {
  return `/api/v1/updates?apps=${encodeURIComponent(JSON.stringify(values))}`;
}

async function postUpdates(values: Array<{ bundleIdentifier: string; version: string; build: string; channel: "stable" | "beta" }>): Promise<Response> {
  return app.request("/api/v1/updates", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ apps: values }),
  }, environment);
}

async function postAppLookup(bundleIdentifiers: string[], channel: "stable" | "beta" = "stable"): Promise<Response> {
  return app.request("/api/v1/apps/lookup", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ bundleIdentifiers, channel }),
  }, environment);
}

describe("DreyzeStore catalog API", () => {
  it("returns health only when D1 responds and includes a request ID", async () => {
    const response = await request("/api/v1/health");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ data: { status: "ok", database: "ready" } });
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("x-request-id")).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("paginates apps and continues with a filter-bound keyset cursor", async () => {
    const firstResponse = await request("/api/v1/apps?limit=2&sort=name");
    const first = await firstResponse.json() as {
      data: Array<{ id: string; shortDescription: string }>;
      meta: { hasMore: boolean; nextCursor: string; page: number; pageSize: number };
    };
    expect(firstResponse.status).toBe(200);
    expect(first.data).toHaveLength(2);
    expect(first.data.every((item) => item.shortDescription.length > 0 && item.shortDescription.length <= 160)).toBe(true);
    expect(first.meta).toMatchObject({ hasMore: true, page: 1, pageSize: 2 });
    expect(first.meta.nextCursor).toBeTruthy();

    const nextResponse = await request(`/api/v1/apps?limit=2&sort=name&cursor=${first.meta.nextCursor}`);
    const next = await nextResponse.json() as { data: Array<{ id: string }>; meta: { hasMore: boolean } };
    expect(nextResponse.status).toBe(200);
    expect(next.data).toHaveLength(2);
    expect(next.data.map((item) => item.id)).not.toEqual(expect.arrayContaining(first.data.map((item) => item.id)));
    expect(next.meta.hasMore).toBe(false);
  });

  it("returns a Unicode-safe short description capped at 160 characters", async () => {
    const longDescription = `${"Orbit 🌱 timer ".repeat(20)}Keeps the day on track.`;
    database.prepare("UPDATE apps SET description = ? WHERE id = ?").run(longDescription, "app-orbit-timer");

    const response = await request("/api/v1/apps?limit=100");
    const body = await response.json() as { data: Array<{ id: string; shortDescription: string }> };
    const timer = body.data.find((item) => item.id === "app-orbit-timer");
    expect(response.status).toBe(200);
    expect(Array.from(timer?.shortDescription ?? "")).toHaveLength(160);
    expect(timer?.shortDescription.endsWith("…")).toBe(true);
    expect(timer?.shortDescription).not.toContain("\uFFFD");
  });

  it("filters by category and repository and accepts bounded page numbers", async () => {
    const category = await request("/api/v1/apps?category=utilities");
    const categoryBody = await category.json() as { data: Array<{ category: { id: string } }> };
    expect(category.status).toBe(200);
    expect(categoryBody.data.map((item) => item.category.id)).toEqual(["utilities"]);

    const repository = await request("/api/v1/apps?repository=com.dreyze.community");
    const repositoryBody = await repository.json() as { data: Array<{ repositoryIdentifier: string }> };
    expect(repositoryBody.data.map((item) => item.repositoryIdentifier)).toEqual(["com.dreyze.community"]);

    const page = await request("/api/v1/apps?page=2&limit=1");
    expect((await page.json() as { meta: { page: number } }).meta.page).toBe(2);
  });

  it("returns full app details with developer, category, latest stable version and screenshots", async () => {
    const response = await request("/api/v1/apps/app-aurora-notes");
    const body = await response.json() as { data: {
      description: string;
      developer: { name: string };
      category: { name: string };
      currentVersion: { version: string; minimumOSVersion: string };
      screenshots: Array<{ url: string; alt: string }>;
    } };
    expect(response.status).toBe(200);
    expect(body.data.developer.name).toContain("Dreyze Labs");
    expect(body.data.category.name).toBe("Productivity");
    expect(body.data.currentVersion).toMatchObject({ version: "1.1.0", minimumOSVersion: "16.0" });
    expect(body.data.screenshots[0]).toMatchObject({
      url: "https://assets.example.invalid/screenshots/aurora-notes/overview.png",
      alt: expect.any(String),
    });
  });

  it("returns a standard 404 for a nonexistent or unpublished app", async () => {
    for (const id of ["does-not-exist", "app-hidden-demo"]) {
      const response = await request(`/api/v1/apps/${id}`);
      expect(response.status).toBe(404);
      const body = await response.json() as { error: { code: string; requestId: string } };
      expect(body.error.code).toBe("not_found");
      expect(body.error.requestId).toBe(response.headers.get("x-request-id"));
    }
  });

  it("returns only published version history in newest-first order", async () => {
    const response = await request("/api/v1/apps/app-aurora-notes/versions");
    const body = await response.json() as { data: Array<{ version: string }> };
    expect(response.status).toBe(200);
    expect(body.data.map((version) => version.version)).toEqual(["2.0.0-beta.1", "1.1.0", "1.0.0"]);
    expect(body.data).not.toContainEqual(expect.objectContaining({ version: "1.2.0" }));
  });

  it("resolves only published apps for update inventory reconciliation", async () => {
    const response = await postAppLookup([
      "com.dreyze.auroranotes",
      "com.dreyze.patchboard",
      "com.dreyze.hidden",
    ]);
    const body = await response.json() as { data: Array<{ bundleIdentifier: string; currentVersion: { version: string } }> };
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(body.data.map((item) => item.bundleIdentifier)).toEqual([
      "com.dreyze.auroranotes",
      "com.dreyze.patchboard",
    ]);
    expect(body.data.find((item) => item.bundleIdentifier === "com.dreyze.auroranotes")?.currentVersion.version).toBe("1.1.0");
    const beta = await postAppLookup(["com.dreyze.auroranotes"], "beta");
    expect((await beta.json() as { data: Array<{ currentVersion: { version: string } }> }).data[0]?.currentVersion.version).toBe("2.0.0-beta.1");
  });

  it("rejects malformed and oversized app lookup requests", async () => {
    expect((await postAppLookup(Array.from({ length: 26 }, (_, index) => `com.example.app${index}`))).status).toBe(413);
    expect((await postAppLookup(["com.example.app", "com.example.app"])).status).toBe(400);
    expect((await postAppLookup(["com.example.app"], "invalid" as "stable")).status).toBe(400);
  });

  it("returns all canonical categories with published app counts", async () => {
    const response = await request("/api/v1/categories");
    const body = await response.json() as { data: Array<{ id: string; name: string; appCount: number }> };
    expect(response.status).toBe(200);
    expect(body.data).toHaveLength(9);
    expect(body.data.find((category) => category.id === "productivity")?.appCount).toBe(1);
    expect(body.data.find((category) => category.id === "other")?.appCount).toBe(0);
  });

  it("returns configured featured sections in stable section and item order", async () => {
    const response = await request("/api/v1/featured");
    const body = await response.json() as { data: Array<{ key: string; items: Array<{ id: string }> }> };
    expect(response.status).toBe(200);
    expect(body.data.map((section) => section.key)).toEqual(["hero", "editors-picks", "new-releases"]);
    expect(body.data[0]!.items.map((item) => item.id)).toEqual(["app-aurora-notes"]);
    expect(body.data[1]!.items.map((item) => item.id)).toEqual(["app-patchboard", "app-orbit-timer"]);
    expect(body.data.flatMap((section) => section.items).map((item) => item.id)).not.toContain("app-hidden-demo");
  });

  it("searches names, developers, bundle identifiers, descriptions and category names", async () => {
    for (const query of ["Aurora", "Orbit Workshop", "com.dreyze.patchboard", "Fictional customization", "Productivity"]) {
      const response = await request(`/api/v1/search?q=${encodeURIComponent(query)}`);
      const body = await response.json() as { data: Array<{ id: string }> };
      expect(response.status).toBe(200);
      expect(body.data.length).toBeGreaterThan(0);
    }
  });

  it("returns an empty result for an empty search instead of listing the catalog", async () => {
    const response = await request("/api/v1/search?q=%20%20");
    const body = await response.json() as { data: unknown[]; meta: { hasMore: boolean } };
    expect(response.status).toBe(200);
    expect(body).toMatchObject({ data: [], meta: { hasMore: false } });
  });

  it("generates a manifest that passes the shared repository v1 validator", async () => {
    const response = await request("/api/v1/repository");
    const manifest = await response.json() as RepositoryManifest;
    expect(response.status).toBe(200);
    expect(validateRepository(manifest)).toMatchObject({ valid: true });
    expect(manifest.apps.map((item) => item.bundleIdentifier)).toEqual([
      "com.dreyze.auroranotes",
      "com.dreyze.orbittimer",
      "com.dreyze.patchboard",
    ]);
    expect(manifest.apps[0]!.versions.map((item) => item.version)).toContain("2.0.0-beta.1");
    expect(manifest.apps[0]!.versions.map((item) => item.version)).not.toContain("1.2.0");
  });

  it("reports only newer published stable updates using semantic precedence", async () => {
    const response = await request(updatesURL([
      { bundleIdentifier: "com.dreyze.auroranotes", installedVersion: "1.0.0" },
      { bundleIdentifier: "com.dreyze.orbittimer", installedVersion: "1.9.0" },
    ]));
    const body = await response.json() as { data: Array<{ installedVersion: string; latestVersion: { version: string } }> };
    expect(response.status).toBe(200);
    expect(body.data.map((entry) => [entry.installedVersion, entry.latestVersion.version])).toEqual([
      ["1.0.0", "1.1.0"],
      ["1.9.0", "1.10.0"],
    ]);
  });

  it("does not return a stable update older than an installed prerelease", async () => {
    const response = await request(updatesURL([
      { bundleIdentifier: "com.dreyze.auroranotes", installedVersion: "2.0.0-beta.1" },
    ]));
    expect((await response.json() as { data: unknown[] }).data).toEqual([]);
  });

  it("does not return an update when installed version matches the latest stable release", async () => {
    const response = await request(updatesURL([
      { bundleIdentifier: "com.dreyze.orbittimer", installedVersion: "1.10.0" },
    ]));
    expect(response.status).toBe(200);
    expect((await response.json() as { data: unknown[] }).data).toEqual([]);
  });

  it("detects a higher build for the same version and never offers a lower release", async () => {
    const higherBuild = await postUpdates([
      { bundleIdentifier: "com.dreyze.orbittimer", version: "1.10.0", build: "9", channel: "stable" },
    ]);
    expect(higherBuild.status).toBe(200);
    expect((await higherBuild.json() as { data: Array<{ installedBuild: string; latestVersion: { version: string; build: string; size: number; sha256: string; downloadURL: string } }> }).data).toMatchObject([
      { installedBuild: "9", latestVersion: { version: "1.10.0", build: "10", size: 1_000_000, sha256: expect.stringMatching(/^[a-f0-9]{64}$/), downloadURL: expect.stringMatching(/^https:\/\//) } },
    ]);

    const sameBuild = await postUpdates([
      { bundleIdentifier: "com.dreyze.orbittimer", version: "1.10.0", build: "10", channel: "stable" },
    ]);
    expect((await sameBuild.json() as { data: unknown[] }).data).toEqual([]);
    const installedIsNewer = await postUpdates([
      { bundleIdentifier: "com.dreyze.orbittimer", version: "1.11.0", build: "1", channel: "stable" },
    ]);
    expect((await installedIsNewer.json() as { data: unknown[] }).data).toEqual([]);
  });

  it("keeps beta releases out of stable update checks and returns beta only to beta users", async () => {
    const stable = await postUpdates([
      { bundleIdentifier: "com.dreyze.auroranotes", version: "1.1.0", build: "2", channel: "stable" },
    ]);
    expect((await stable.json() as { data: unknown[] }).data).toEqual([]);
    const beta = await postUpdates([
      { bundleIdentifier: "com.dreyze.auroranotes", version: "1.1.0", build: "2", channel: "beta" },
    ]);
    expect((await beta.json() as { data: Array<{ channel: string; latestVersion: { channel: string; version: string } }> }).data).toMatchObject([
      { channel: "beta", latestVersion: { channel: "beta", version: "2.0.0-beta.1" } },
    ]);
  });

  it("rejects malformed POST bodies, unknown fields, unsupported channels, and oversized batches", async () => {
    for (const [headers, body] of [
      [{ "content-type": "text/plain" }, "{}"],
      [{ "content-type": "application/json" }, "{"],
      [{ "content-type": "application/json" }, JSON.stringify({ apps: [{ bundleIdentifier: "com.example.app", version: "1", build: "1", channel: "stable", extra: true }] })],
      [{ "content-type": "application/json" }, JSON.stringify({ apps: [{ bundleIdentifier: "com.example.app", version: "1", build: "1", channel: "nightly" }] })],
      [{ "content-type": "application/json" }, JSON.stringify({ apps: Array.from({ length: 26 }, (_, index) => ({ bundleIdentifier: `com.example.app${index}`, version: "1", build: "1", channel: "stable" })) })],
    ] as const) {
      const response = await app.request("/api/v1/updates", { method: "POST", headers, body }, environment);
      expect([400, 413, 415]).toContain(response.status);
    }
  });

  it("rejects malformed or ambiguous update inputs", async () => {
    const invalidInputs = [
      "",
      "%7B%7D",
      "%5B1%5D",
      encodeURIComponent(JSON.stringify([{ bundleIdentifier: "bad", installedVersion: "1.0.0" }])),
      encodeURIComponent(JSON.stringify([{ bundleIdentifier: "com.example.app", installedVersion: "1.0.0.0" }])),
      encodeURIComponent(JSON.stringify([{ bundleIdentifier: "com.example.app", installedVersion: "1.0.0", extra: true }])),
      encodeURIComponent(JSON.stringify([
        { bundleIdentifier: "com.example.app", installedVersion: "1.0.0" },
        { bundleIdentifier: "com.example.app", installedVersion: "2.0.0" },
      ])),
    ];
    for (const input of invalidInputs) {
      expect((await request(`/api/v1/updates?apps=${input}`)).status).toBe(400);
    }

    const valid = await request(updatesURL([
      { bundleIdentifier: "com.dreyze.orbittimer", installedVersion: "1.9.0" },
    ]));
    expect(valid.headers.get("cache-control")).toBe("no-store");
  });

  it("rejects malformed pagination, filters, duplicate parameters, and cursor reuse", async () => {
    for (const path of [
      "/api/v1/apps?page=0",
      "/api/v1/apps?page=1001",
      "/api/v1/apps?limit=101",
      "/api/v1/apps?page=1&page=2",
      "/api/v1/apps?sort=ranked",
      "/api/v1/apps?category=utilities%27%20OR%201%3D1--",
      "/api/v1/apps?repository=repo%27%20OR%201%3D1--",
      "/api/v1/apps?cursor=not-a-cursor",
      "/api/v1/apps?cursor=eyJ2IjoxLCJzb3J0IjoibmFtZSJ9",
    ]) {
      const response = await request(path);
      expect(response.status).toBe(400);
      expect((await response.json() as { error: { requestId?: string } }).error.requestId).toBeTruthy();
    }

    const cursorResponse = await request("/api/v1/apps?limit=1");
    const cursorBody = await cursorResponse.json() as { meta: { nextCursor: string } };
    const mismatch = await request(`/api/v1/apps?sort=updated&cursor=${cursorBody.meta.nextCursor}`);
    expect(mismatch.status).toBe(400);
  });

  it("rejects oversized search and update requests", async () => {
    expect((await request(`/api/v1/search?q=${"x".repeat(101)}`)).status).toBe(400);
    expect((await request(`/api/v1/updates?apps=${"x".repeat(2501)}`)).status).toBe(413);
    const oversizedList = Array.from({ length: 26 }, (_, index) => ({
      bundleIdentifier: `com.example.app${index}`,
      installedVersion: "1.0.0",
    }));
    expect((await request(updatesURL(oversizedList))).status).toBe(413);
    expect((await request(`/api/v1/apps?${"q=x&".repeat(2100)}`)).status).toBe(414);
  });

  it("treats FTS operators and SQL-looking text as literal search tokens", async () => {
    const response = await request(`/api/v1/search?q=${encodeURIComponent('" OR 1=1; DROP TABLE apps;--')}`);
    expect(response.status).toBe(200);
    expect((await response.json() as { data: unknown[] }).data).toEqual([]);
    expect(database.prepare("SELECT COUNT(*) AS count FROM apps").get()).toMatchObject({ count: 5 });
  });

  it("does not leak object keys, rights flags, admin tables, or audit data", async () => {
    const [detailsResponse, repositoryResponse] = await Promise.all([
      request("/api/v1/apps/app-aurora-notes"),
      request("/api/v1/repository"),
    ]);
    const output = `${JSON.stringify(await detailsResponse.json())}${JSON.stringify(await repositoryResponse.json())}`;
    for (const internalValue of [
      "ipa_object_key",
      "icon_object_key",
      "distribution_rights_attested",
      "audit_logs",
      "admin_sessions",
    ]) {
      expect(output).not.toContain(internalValue);
    }
  });

  it("sets ETags for public catalog responses and serves conditional requests", async () => {
    const firstResponse = await request("/api/v1/apps");
    const etag = firstResponse.headers.get("etag");
    expect(etag).toMatch(/^"[a-f0-9]{64}"$/);
    expect(firstResponse.headers.get("cache-control")).toContain("public");
    const secondResponse = await request("/api/v1/apps", { "If-None-Match": etag! });
    expect(secondResponse.status).toBe(304);
    expect(secondResponse.headers.get("etag")).toBe(etag);
  });

  it("does not grant wildcard CORS access", async () => {
    const response = await request("/api/v1/categories", { Origin: "https://untrusted.example" });
    expect(response.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("does not serve a release whose app or release is unpublished", async () => {
    const versions = await request("/api/v1/apps/app-aurora-notes/versions");
    const returnedVersions = await versions.json() as { data: Array<{ version: string }> };
    expect(returnedVersions.data.some((version) => version.version === "1.2.0")).toBe(false);
    const search = await request("/api/v1/search?q=Hidden");
    expect((await search.json() as { data: unknown[] }).data).toEqual([]);
  });

  it("uses the shared error envelope and request ID for unknown routes", async () => {
    const response = await request("/api/v1/no-such-route");
    const body = await response.json() as { error: { code: string; requestId: string } };
    expect(response.status).toBe(404);
    expect(body.error.code).toBe("not_found");
    expect(body.error.requestId).toBe(response.headers.get("x-request-id"));
  });
});
