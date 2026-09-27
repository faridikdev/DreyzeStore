import { Hono } from "hono";
import type { WorkerEnvironment } from "../env.js";
import { readHealth } from "../services/healthService.js";
import { ApiError, apiErrorResponse, type ApiVariables } from "../errors.js";

export const healthRoutes = new Hono<{
  Bindings: WorkerEnvironment;
  Variables: ApiVariables;
}>().get("/", async (context) => {
  try {
    const health = await readHealth(context.env);
    if (!health) {
      return apiErrorResponse(context, new ApiError(
        503,
        "service_unavailable",
        "The service is not ready.",
      ));
    }

    context.header("Cache-Control", "no-store");
    return context.json({ data: health });
  } catch {
    return apiErrorResponse(context, new ApiError(
      503,
      "service_unavailable",
      "The service is not ready.",
    ));
  }
});
