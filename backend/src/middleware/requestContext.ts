import type { MiddlewareHandler } from "hono";
import type { WorkerEnvironment } from "../env.js";

export const requestContext: MiddlewareHandler<{
  Bindings: WorkerEnvironment;
  Variables: { requestId: string };
}> = async (context, next) => {
  const requestId = context.req.header("cf-ray") ?? crypto.randomUUID();
  context.set("requestId", requestId);
  await next();
  context.header("X-Request-Id", requestId);
};
