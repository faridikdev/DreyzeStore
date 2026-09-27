import { Hono } from "hono";
import { cors } from "hono/cors";
import type { WorkerEnvironment } from "./env.js";
import { healthRoutes } from "./routes/health.js";
import { catalogRoutes } from "./routes/catalog.js";
import { adminAuthRoutes } from "./routes/adminAuth.js";
import { adminRoutes, validatorRoutes } from "./routes/admin.js";
import { requestContext } from "./middleware/requestContext.js";
import { securityHeaders } from "./middleware/securityHeaders.js";
import { ApiError, apiErrorResponse, type ApiContext, type ApiVariables } from "./errors.js";

type AppEnvironment = { Bindings: WorkerEnvironment; Variables: ApiVariables };

export const app = new Hono<AppEnvironment>();

app.use("*", requestContext);
app.use("*", securityHeaders);
app.use("/api/*", async (context, next) => {
  if (context.req.url.length > 8192) {
    throw new ApiError(414, "uri_too_long", "The request URL is too long.");
  }

  const origins = (context.env.ADMIN_ORIGINS ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);

  const isAdminRoute = context.req.path.startsWith("/api/v1/admin/");
  return cors({
    origin: (origin) => (origins.includes(origin) ? origin : null),
    allowMethods: isAdminRoute ? ["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"] : ["GET", "OPTIONS"],
    allowHeaders: ["Content-Type", "If-None-Match", "X-CSRF-Token"],
    exposeHeaders: ["ETag", "X-Request-Id"],
    maxAge: 600,
    credentials: isAdminRoute,
  })(context, next);
});

app.route("/api/v1/health", healthRoutes);
const v1Routes = new Hono<{ Bindings: WorkerEnvironment; Variables: ApiVariables }>();
catalogRoutes(v1Routes);
v1Routes.route("/", adminAuthRoutes);
v1Routes.route("/", adminRoutes);
v1Routes.route("/", validatorRoutes);
app.route("/api/v1", v1Routes);

app.notFound((context) => apiErrorResponse(context as ApiContext, new ApiError(
  404,
  "not_found",
  "The requested resource was not found.",
)));

app.onError((error, context) => {
  if (error instanceof ApiError) return apiErrorResponse(context as ApiContext, error);
  if (error instanceof URIError) {
    return apiErrorResponse(context as ApiContext, new ApiError(400, "invalid_path", "The request path is invalid."));
  }
  // Internal D1/Worker diagnostics stay out of the public response.
  return apiErrorResponse(context as ApiContext, new ApiError(
    500,
    "internal_error",
    "The request could not be completed.",
  ));
});
