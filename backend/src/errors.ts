import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { WorkerEnvironment } from "./env.js";

export interface AdminPrincipal {
  id: string;
  email: string;
  role: "admin" | "editor";
}

export type ApiVariables = {
  requestId: string;
  admin: AdminPrincipal;
  adminSessionHash: string;
  adminCsrfHash: string;
  adminSessionExpiresAt: string;
};
export type ApiContext = Context<{ Bindings: WorkerEnvironment; Variables: ApiVariables }>;

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: Record<string, string[]>,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function apiErrorResponse(context: ApiContext, error: ApiError): Response {
  context.header("Cache-Control", "no-store");
  return context.json(
    {
      error: {
        code: error.code,
        message: error.message,
        requestId: context.get("requestId"),
        ...(error.details ? { details: error.details } : {}),
      },
    },
    error.status as ContentfulStatusCode,
  );
}

export function validationError(field: string, message: string): ApiError {
  return new ApiError(400, "invalid_request", "The request parameters are invalid.", {
    [field]: [message],
  });
}
