import { describe, expect, it, vi } from "vitest";
import { app } from "./app.js";
import type { WorkerEnvironment } from "./env.js";

function createEnvironment(databaseResult: unknown = { ready: 1 }): WorkerEnvironment {
  const database = {
    prepare: vi.fn(() => ({
      first: vi.fn(async () => databaseResult),
    })),
  } as unknown as D1Database;

  return {
    DB: database,
    PUBLIC_ASSETS: {} as R2Bucket,
    STAGING_ASSETS: {} as R2Bucket,
    ADMIN_ORIGINS: "http://localhost:5173",
  };
}

describe("API foundation", () => {
  it("returns health only when D1 responds", async () => {
    const response = await app.request("/api/v1/health", {}, createEnvironment());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ data: { status: "ok", database: "ready" } });
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("does not report readiness when the D1 check fails", async () => {
    const response = await app.request("/api/v1/health", {}, createEnvironment(null));

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: { code: "service_unavailable", message: "The service is not ready." },
    });
  });

  it("returns the common not found envelope for routes not implemented in this phase", async () => {
    const response = await app.request("/api/v1/apps", {}, createEnvironment());

    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({
      error: { code: "not_found", message: "The requested resource was not found." },
    });
  });
});
