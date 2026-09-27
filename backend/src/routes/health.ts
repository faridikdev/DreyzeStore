import { Hono } from "hono";
import type { WorkerEnvironment } from "../env.js";
import { readHealth } from "../services/healthService.js";

export const healthRoutes = new Hono<{ Bindings: WorkerEnvironment }>().get("/", async (context) => {
  try {
    const health = await readHealth(context.env);
    if (!health) {
      return context.json({ error: { code: "service_unavailable", message: "The service is not ready." } }, 503);
    }

    context.header("Cache-Control", "no-store");
    return context.json({ data: health });
  } catch {
    return context.json({ error: { code: "service_unavailable", message: "The service is not ready." } }, 503);
  }
});
