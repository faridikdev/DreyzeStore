import { Hono } from "hono";
import { cors } from "hono/cors";
import type { WorkerEnvironment } from "./env.js";
import { healthRoutes } from "./routes/health.js";
import { requestContext } from "./middleware/requestContext.js";
import { securityHeaders } from "./middleware/securityHeaders.js";

export const app = new Hono<{
  Bindings: WorkerEnvironment;
  Variables: { requestId: string };
}>();

app.use("*", requestContext);
app.use("*", securityHeaders);
app.use("/api/*", async (context, next) => {
  const origins = (context.env.ADMIN_ORIGINS ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);

  return cors({
    origin: (origin) => (origins.includes(origin) ? origin : null),
    allowMethods: ["GET", "OPTIONS"],
    allowHeaders: ["Content-Type", "X-Request-Id"],
    maxAge: 600,
  })(context, next);
});

app.route("/api/v1/health", healthRoutes);

app.notFound((context) =>
  context.json(
    {
      error: {
        code: "not_found",
        message: "The requested resource was not found.",
        requestId: context.get("requestId"),
      },
    },
    404,
  ),
);

app.onError((error, context) => {
  // Keep internal error details out of public responses. Structured logging is
  // intentionally deferred until request redaction and retention are defined.
  void error;
  return context.json(
    {
      error: {
        code: "internal_error",
        message: "The request could not be completed.",
        requestId: context.get("requestId"),
      },
    },
    500,
  );
});
