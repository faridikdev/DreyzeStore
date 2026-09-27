import assert from "node:assert/strict";
import { validateRepository } from "../shared/src/repositoryValidator.ts";

const baseUrl = new URL(process.env.DREYZESTORE_API_URL ?? "http://127.0.0.1:8787");
if (!new Set(["127.0.0.1", "localhost", "[::1]", "::1"]).has(baseUrl.hostname)) {
  throw new Error("Local API smoke checks only run against localhost.");
}

async function get(path) {
  const response = await fetch(new URL(path, baseUrl));
  assert.equal(response.status, 200, `${path}: expected HTTP 200, received ${response.status}`);
  assert.ok(response.headers.get("x-request-id"), `${path}: missing request ID`);
  return { response, body: await response.json() };
}

const health = await get("/api/v1/health");
assert.deepEqual(health.body.data, { status: "ok", database: "ready" });

const apps = await get("/api/v1/apps?limit=2");
assert.equal(apps.body.data.length, 2);
assert.equal(apps.body.meta.hasMore, true);
assert.ok(apps.body.meta.nextCursor);
assert.ok(apps.body.data.some((item) => item.id === "app-aurora-notes"));

const details = await get("/api/v1/apps/app-aurora-notes");
assert.equal(details.body.data.currentVersion.version, "1.1.0");
assert.equal(details.body.data.screenshots.length, 1);

const categories = await get("/api/v1/categories");
assert.equal(categories.body.data.length, 9);

const featured = await get("/api/v1/featured");
assert.equal(featured.body.data[0].key, "hero");

const search = await get("/api/v1/search?q=Orbit%20Workshop");
assert.ok(search.body.data.some((item) => item.id === "app-orbit-timer"));

const updateInput = encodeURIComponent(JSON.stringify([{
  bundleIdentifier: "com.dreyze.orbittimer",
  installedVersion: "1.9.0",
}]));
const updates = await get(`/api/v1/updates?apps=${updateInput}`);
assert.equal(updates.body.data[0].latestVersion.version, "1.10.0");
assert.equal(updates.response.headers.get("cache-control"), "no-store");

const repository = await get("/api/v1/repository");
const repositoryValidation = validateRepository(repository.body);
assert.equal(repositoryValidation.valid, true, JSON.stringify(repositoryValidation));

console.log("Local D1 API smoke checks passed: health, pagination, details, categories, featured, search, updates, repository schema.");
