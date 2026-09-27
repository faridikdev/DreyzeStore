import type { AdminPrincipal } from "../errors.js";

export interface PasswordAccountRow {
  id: string;
  subject: string;
  role: "admin" | "editor";
  enabled: number;
  password_hash: string | null;
  password_salt: string | null;
  password_iterations: number | null;
  password_algorithm: string | null;
  password_memory_kib: number | null;
  password_parallelism: number | null;
}

export interface AdminSessionRow extends AdminPrincipal {
  csrf_sha256: string;
  expires_at: string;
  revoked_at: string | null;
}

export async function findPasswordAccount(database: D1Database, email: string): Promise<PasswordAccountRow | null> {
  return database.prepare(
    "SELECT u.id, u.subject, u.role, u.enabled, p.password_hash, p.password_salt, " +
    "p.iterations AS password_iterations, p.algorithm AS password_algorithm, " +
    "p.memory_kib AS password_memory_kib, p.parallelism AS password_parallelism " +
    "FROM admin_users AS u LEFT JOIN admin_password_credentials AS p ON p.admin_user_id = u.id " +
    "WHERE u.provider = 'password' AND u.subject = ? LIMIT 1",
  ).bind(email).first<PasswordAccountRow>();
}

export async function findSession(database: D1Database, tokenHash: string): Promise<AdminSessionRow | null> {
  return database.prepare(
    "SELECT u.id, u.subject AS email, u.role, s.csrf_sha256, s.expires_at, s.revoked_at " +
    "FROM admin_sessions AS s JOIN admin_users AS u ON u.id = s.admin_user_id " +
    "WHERE s.token_sha256 = ? AND u.provider = 'password' AND u.enabled = 1 LIMIT 1",
  ).bind(tokenHash).first<AdminSessionRow>();
}

export async function writeAudit(
  database: D1Database,
  event: {
    id: string;
    adminUserId: string | null;
    actorSubject: string;
    action: string;
    resourceType: string;
    resourceId?: string | null;
    requestId?: string | null;
    ipMetadata?: string | null;
  },
): Promise<void> {
  await database.prepare(
    "INSERT INTO audit_logs (id, admin_user_id, actor_subject, action, resource_type, resource_id, request_id, ip_metadata) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  ).bind(
    event.id,
    event.adminUserId,
    event.actorSubject.slice(0, 255),
    event.action,
    event.resourceType,
    event.resourceId ?? null,
    event.requestId ?? null,
    event.ipMetadata ?? null,
  ).run();
}

export function auditStatement(
  database: D1Database,
  event: {
    id: string;
    adminUserId: string | null;
    actorSubject: string;
    action: string;
    resourceType: string;
    resourceId?: string | null;
    requestId?: string | null;
    ipMetadata?: string | null;
  },
): D1PreparedStatement {
  return database.prepare(
    "INSERT INTO audit_logs (id, admin_user_id, actor_subject, action, resource_type, resource_id, request_id, ip_metadata) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  ).bind(
    event.id,
    event.adminUserId,
    event.actorSubject.slice(0, 255),
    event.action,
    event.resourceType,
    event.resourceId ?? null,
    event.requestId ?? null,
    event.ipMetadata ?? null,
  );
}
