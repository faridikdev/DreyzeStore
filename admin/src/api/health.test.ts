import { describe, expect, it, vi } from "vitest";
import { AdminApiError, checkApiHealth } from "./health.js";

describe("admin API health client", () => {
  it("reads health from the configured API endpoint", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ data: { status: "ok", database: "ready" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    await expect(checkApiHealth("http://localhost:8787/api/v1/", fetchMock)).resolves.toEqual({
      status: "ok",
      database: "ready",
    });
    expect(fetchMock).toHaveBeenCalledWith(
      new URL("http://localhost:8787/api/v1/health"),
      expect.objectContaining({ headers: { Accept: "application/json" } }),
    );
  });

  it("does not allow a non-HTTPS remote endpoint", async () => {
    await expect(checkApiHealth("http://api.example.com/api/v1", vi.fn())).rejects.toThrow(AdminApiError);
  });

  it("does not expose network exception details", async () => {
    const fetchMock = vi.fn(async () => {
      throw new Error("private transport details");
    });

    await expect(checkApiHealth("https://api.example.com/api/v1", fetchMock)).rejects.toThrow(
      "The API could not be reached.",
    );
  });
});
