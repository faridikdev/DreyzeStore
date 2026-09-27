import { getCookie } from "hono/cookie";
import type { Context, MiddlewareHandler } from "hono";
import { ApiError, type ApiVariables } from "../errors.js";
import type { WorkerEnvironment } from "../env.js";
import { constantTimeHexEquals, hmacSha256Hex, sha256Hex } from "./crypto.js";
import { findSession } from "../repositories/adminRepository.js";

export type AdminEnvironment = { Bindings: WorkerEnvironment; Variables: ApiVariables };
export const SESSION_TTL_SECONDS = 8 * 60 * 60;
export const LOGIN_FAILURE_LIMIT = 5;
export const LOGIN_WINDOW_SECONDS = 15 * 60;

export function secureAdminCookies(environment: WorkerEnvironment): boolean {
  // HTTPS is the production-safe default. Only an explicit local setting opts out.
  return environment.SECURE_COOKIES !== "false";
}

export function adminCookieName(environment: WorkerEnvironment): string {
  return secureAdminCookies(environment) ? "__Host-dreyzestore_session" : "dreyzestore_session";
}

export function adminCookieOptions(environment: WorkerEnvironment) {
  return {
    httpOnly: true,
    secure: secureAdminCookies(environment),
    sameSite: "Lax" as const,
    path: "/",
    maxAge: SESSION_TTL_SECONDS,
  };
}

export async function deriveCsrfToken(environment: WorkerEnvironment, rawSessionToken: string): Promise<string> {
  const secret = environment.ADMIN_CSRF_SECRET;
  if (!secret || secret.length < 32) {
    throw new ApiError(503, "admin_auth_unavailable", "Admin authentication is not configured.");
  }
  return hmacSha256Hex(secret, "dreyzestore-csrf-v1:" + rawSessionToken);
}

export function requireAdmin(): MiddlewareHandler<AdminEnvironment> {
  return async (context, next) => {
    const rawToken = getCookie(context, adminCookieName(context.env));
    if (!rawToken || !/^[A-Za-z0-9_-]{40,64}$/u.test(rawToken)) {
      throw new ApiError(401, "unauthenticated", "Sign in to continue.");
    }
    const sessionHash = await sha256Hex(rawToken);
    const session = await findSession(context.env.DB, sessionHash);
    if (!session || session.revoked_at !== null || Date.parse(session.expires_at) <= Date.now()) {
      if (session) {
        await context.env.DB.prepare(
          "UPDATE admin_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE token_sha256 = ?",
        ).bind(sessionHash).run();
      }
      throw new ApiError(401, "session_expired", "Your session has expired. Sign in again.");
    }
    const csrfToken = await deriveCsrfToken(context.env, rawToken);
    const csrfHash = await sha256Hex(csrfToken);
    if (!constantTimeHexEquals(csrfHash, session.csrf_sha256)) {
      await context.env.DB.prepare(
        "UPDATE admin_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE token_sha256 = ?",
      ).bind(sessionHash).run();
      throw new ApiError(401, "session_expired", "Your session is no longer valid. Sign in again.");
    }
    context.set("admin", { id: session.id, email: session.email, role: session.role });
    context.set("adminSessionHash", sessionHash);
    context.set("adminCsrfHash", session.csrf_sha256);
    context.set("adminSessionExpiresAt", session.expires_at);
    context.header("Cache-Control", "no-store");
    await next();
  };
}

export function requireRole(...roles: Array<"admin" | "editor">): MiddlewareHandler<AdminEnvironment> {
  return async (context, next) => {
    const principal = context.get("admin");
    if (!principal || !roles.includes(principal.role)) {
      throw new ApiError(403, "forbidden", "Your account cannot perform this action.");
    }
    await next();
  };
}

export function assertAdminOrigin(context: Context<AdminEnvironment>): void {
  const origin = context.req.header("Origin");
  const allowedOrigins = (context.env.ADMIN_ORIGINS ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  if (!origin || !allowedOrigins.includes(origin)) {
    throw new ApiError(403, "origin_rejected", "The request origin is not allowed.");
  }
  if (context.req.header("Sec-Fetch-Site") === "cross-site") {
    throw new ApiError(403, "origin_rejected", "Cross-site state changes are not allowed.");
  }
}

export async function assertCsrf(context: Context<AdminEnvironment>): Promise<void> {
  assertAdminOrigin(context);
  const supplied = context.req.header("X-CSRF-Token") ?? "";
  const suppliedHash = await sha256Hex(supplied);
  if (!constantTimeHexEquals(suppliedHash, context.get("adminCsrfHash"))) {
    throw new ApiError(403, "csrf_rejected", "The request could not be verified. Refresh the admin page and try again.");
  }
}

export function maskedIpMetadata(request: Request): string | null {
  const address = (request.headers.get("CF-Connecting-IP") ?? "").trim();
  if (!address) return null;
  const ipv4 = address.split(".");
  if (ipv4.length === 4 && ipv4.every((part) => /^\d{1,3}$/u.test(part) && Number(part) <= 255)) {
    return ipv4.slice(0, 3).join(".") + ".0/24";
  }
  if (address.includes(":") && /^[0-9a-f:]+$/iu.test(address)) {
    const prefix = address.split("::")[0] ?? "";
    return prefix.split(":").slice(0, 4).join(":") + "::/64";
  }
  return null;
}
