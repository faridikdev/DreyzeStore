import { Hono } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";
import { auditStatement, findPasswordAccount, writeAudit } from "../repositories/adminRepository.js";
import { assertAdminOrigin, assertCsrf, adminCookieName, adminCookieOptions, deriveCsrfToken, maskedIpMetadata, requireAdmin, secureAdminCookies, LOGIN_FAILURE_LIMIT, LOGIN_WINDOW_SECONDS, SESSION_TTL_SECONDS } from "../security/adminSecurity.js";
import { hmacSha256Hex, randomToken, sha256Hex } from "../security/crypto.js";
import { readBoundedJson } from "../security/requestBody.js";
import { verifyPassword } from "../security/passwords.js";
import { PASSWORD_HASH_ALGORITHM, PASSWORD_HASH_MEMORY_KIB, PASSWORD_HASH_PASSES, type PasswordHash } from "../security/passwordKdfCore.js";
import type { ApiVariables } from "../errors.js";

type AuthEnvironment = { Bindings: WorkerEnvironment; Variables: ApiVariables };
type LoginInput = { email?: unknown; password?: unknown };
const emailPattern = /^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$/iu;
const dummyHash: PasswordHash = {
  algorithm: PASSWORD_HASH_ALGORITHM,
  iterations: PASSWORD_HASH_PASSES,
  memoryKiB: PASSWORD_HASH_MEMORY_KIB,
  parallelism: 1,
  salt: "0000000000000000000000000000000000000000000000000000000000000000",
  hash: "0000000000000000000000000000000000000000000000000000000000000000",
};

export const adminAuthRoutes = new Hono<AuthEnvironment>();

adminAuthRoutes.post("/admin/auth/login", async (context) => {
  assertAdminOrigin(context);
  const body = await readBoundedJson<LoginInput>(context, 8_192);
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new ApiError(400, "invalid_credentials", "Enter a valid email address and password.");
  }
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (Object.keys(body).some((key) => key !== "email" && key !== "password") ||
      !emailPattern.test(email) || email.length > 254 || encoderBytes(password) > 256) {
    throw new ApiError(400, "invalid_credentials", "Enter a valid email address and password.");
  }

  const rateKey = context.env.ADMIN_RATE_LIMIT_HMAC_KEY;
  const csrfSecret = context.env.ADMIN_CSRF_SECRET;
  if (!rateKey || rateKey.length < 32 || !csrfSecret || csrfSecret.length < 32) {
    throw new ApiError(503, "admin_auth_unavailable", "Admin authentication is not configured.");
  }
  const ip = context.req.header("CF-Connecting-IP") ?? "unknown";
  const emailBucket = await hmacSha256Hex(rateKey, "email:" + email);
  const ipBucket = await hmacSha256Hex(rateKey, "ip:" + ip);
  const now = Date.now();
  const windowStart = new Date(Math.floor(now / (LOGIN_WINDOW_SECONDS * 1000)) * LOGIN_WINDOW_SECONDS * 1000).toISOString();
  const expiresAt = new Date(Date.parse(windowStart) + LOGIN_WINDOW_SECONDS * 1000).toISOString();
  const bucketCounts = await Promise.all([
    consumeLoginBucket(context.env.DB, emailBucket, windowStart, expiresAt),
    consumeLoginBucket(context.env.DB, ipBucket, windowStart, expiresAt),
  ]);
  if (bucketCounts.some((count) => count > LOGIN_FAILURE_LIMIT)) {
    await writeAudit(context.env.DB, {
      id: crypto.randomUUID(),
      adminUserId: null,
      actorSubject: "anonymous:" + (await sha256Hex(email)).slice(0, 24),
      action: "login.rate_limited",
      resourceType: "admin_session",
      requestId: context.get("requestId"),
      ipMetadata: maskedIpMetadata(context.req.raw),
    });
    throw new ApiError(429, "login_rate_limited", "Too many sign-in attempts. Try again in 15 minutes.");
  }

  const account = await findPasswordAccount(context.env.DB, email);
  const passwordRecord: PasswordHash = account?.password_hash && account.password_salt && account.password_iterations &&
      account.password_algorithm && account.password_memory_kib && account.password_parallelism
    ? {
      algorithm: account.password_algorithm as PasswordHash["algorithm"],
      iterations: account.password_iterations,
      memoryKiB: account.password_memory_kib,
      parallelism: account.password_parallelism,
      salt: account.password_salt,
      hash: account.password_hash,
    }
    : dummyHash;
  const verification = await verifyPassword(context.env, password, passwordRecord, emailBucket[0]!);
  if (!account || account.enabled !== 1 || !verification.verified) {
    await writeAudit(context.env.DB, {
      id: crypto.randomUUID(),
      adminUserId: account?.id ?? null,
      actorSubject: account?.subject ?? "anonymous:" + (await sha256Hex(email)).slice(0, 24),
      action: "login.failure",
      resourceType: "admin_session",
      requestId: context.get("requestId"),
      ipMetadata: maskedIpMetadata(context.req.raw),
    });
    throw new ApiError(401, "invalid_credentials", "Email or password was not accepted.");
  }

  if (verification.upgraded) {
    await context.env.DB.prepare(
      "UPDATE admin_password_credentials SET password_hash = ?, password_salt = ?, iterations = ?, algorithm = ?, memory_kib = ?, parallelism = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " +
      "WHERE admin_user_id = ?",
    ).bind(
      verification.upgraded.hash,
      verification.upgraded.salt,
      verification.upgraded.iterations,
      verification.upgraded.algorithm,
      verification.upgraded.memoryKiB,
      verification.upgraded.parallelism,
      account.id,
    ).run();
  }

  const token = randomToken();
  const sessionHash = await sha256Hex(token);
  const csrfToken = await deriveCsrfToken(context.env, token);
  const csrfHash = await sha256Hex(csrfToken);
  const expiresAtSession = new Date(Date.now() + SESSION_TTL_SECONDS * 1000).toISOString();
  await context.env.DB.batch([
    context.env.DB.prepare(
      "INSERT INTO admin_sessions (token_sha256, admin_user_id, csrf_sha256, expires_at) VALUES (?, ?, ?, ?)",
    ).bind(sessionHash, account.id, csrfHash, expiresAtSession),
    context.env.DB.prepare(
      "UPDATE admin_users SET last_auth_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
    ).bind(account.id),
    auditStatement(context.env.DB, {
      id: crypto.randomUUID(),
      adminUserId: account.id,
      actorSubject: account.subject,
      action: "login.success",
      resourceType: "admin_session",
      resourceId: sessionHash.slice(0, 12),
      requestId: context.get("requestId"),
      ipMetadata: maskedIpMetadata(context.req.raw),
    }),
  ]);
  setCookie(context, adminCookieName(context.env), token, adminCookieOptions(context.env));
  context.header("Cache-Control", "no-store");
  return context.json({ data: { id: account.id, email: account.subject, role: account.role, csrfToken, expiresAt: expiresAtSession } });
});

adminAuthRoutes.get("/admin/auth/session", requireAdmin(), async (context) => {
  const token = getCookie(context, adminCookieName(context.env))!;
  const admin = context.get("admin");
  context.header("Cache-Control", "no-store");
  return context.json({
    data: {
      id: admin.id,
      email: admin.email,
      role: admin.role,
      csrfToken: await deriveCsrfToken(context.env, token),
      expiresAt: context.get("adminSessionExpiresAt"),
    },
  });
});

adminAuthRoutes.post("/admin/auth/logout", requireAdmin(), async (context) => {
  await assertCsrf(context);
  const admin = context.get("admin");
  await context.env.DB.batch([
    context.env.DB.prepare(
      "UPDATE admin_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE token_sha256 = ? AND revoked_at IS NULL",
    ).bind(context.get("adminSessionHash")),
    auditStatement(context.env.DB, {
      id: crypto.randomUUID(),
      adminUserId: admin.id,
      actorSubject: admin.email,
      action: "logout",
      resourceType: "admin_session",
      requestId: context.get("requestId"),
      ipMetadata: maskedIpMetadata(context.req.raw),
    }),
  ]);
  deleteCookie(context, adminCookieName(context.env), {
    path: "/",
    secure: secureAdminCookies(context.env),
    sameSite: "Lax",
  });
  context.header("Cache-Control", "no-store");
  return context.json({ data: { signedOut: true } });
});

async function consumeLoginBucket(
  database: D1Database,
  bucketKey: string,
  windowStartedAt: string,
  expiresAt: string,
): Promise<number> {
  const row = await database.prepare(
    "INSERT INTO rate_limit_buckets (bucket_key_sha256, window_started_at, request_count, expires_at) " +
    "VALUES (?, ?, 1, ?) ON CONFLICT(bucket_key_sha256) DO UPDATE SET " +
    "request_count = CASE WHEN window_started_at = excluded.window_started_at THEN request_count + 1 ELSE 1 END, " +
    "window_started_at = excluded.window_started_at, expires_at = excluded.expires_at " +
    "RETURNING request_count",
  ).bind(bucketKey, windowStartedAt, expiresAt).first<{ request_count: number }>();
  return row?.request_count ?? 1;
}

function encoderBytes(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}
