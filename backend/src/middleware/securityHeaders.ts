import type { MiddlewareHandler } from "hono";
import type { WorkerEnvironment } from "../env.js";

export const securityHeaders: MiddlewareHandler<{
  Bindings: WorkerEnvironment;
}> = async (context, next) => {
  await next();
  context.header("X-Content-Type-Options", "nosniff");
  context.header("Referrer-Policy", "no-referrer");
  context.header("X-Frame-Options", "DENY");
  context.header("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
};
