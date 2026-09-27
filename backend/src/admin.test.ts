import { createHash } from "node:crypto";
import { deflateSync } from "node:zlib";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import setupWasm, { type Argon2idParams } from "argon2id/lib/setup.js";
import { validateRepository } from "@dreyzestore/shared/repository-validator";
import type { WorkerEnvironment } from "./env.js";
import { app } from "./app.js";
import { hashPassword, verifyPasswordRecord, type Argon2idDerive, type PasswordHash } from "./security/passwordKdfCore.js";

const sourceDirectory = dirname(fileURLToPath(import.meta.url));
const rootDirectory = resolve(sourceDirectory, "../..");
const migrationDirectory = resolve(sourceDirectory, "../migrations");
const seedPath = resolve(sourceDirectory, "../seeds/dev.sql");
const validatorPath = resolve(rootDirectory, "scripts/validate_ipa.py");
const testPassword = "safe-development-password-2026";
const oidcAudience = "https://api.example.invalid/validator";
let signingKey: CryptoKey;
let publicJwk: JsonWebKey & { kid: string };
let passwordRecord: PasswordHash;
let derivePasswordHash: Argon2idDerive;
let database: DatabaseSync;
let environment: WorkerEnvironment;
let staging: MemoryBucket;
let published: MemoryBucket;

beforeAll(async () => {
  const kdfDirectory = dirname(fileURLToPath(import.meta.resolve("argon2id/lib/setup.js")));
  const simdModule = await WebAssembly.compile(readFileSync(resolve(kdfDirectory, "../dist/simd.wasm")));
  const nonSimdModule = await WebAssembly.compile(readFileSync(resolve(kdfDirectory, "../dist/no-simd.wasm")));
  const derive = await setupWasm(
    async (imports) => ({ module: simdModule, instance: await WebAssembly.instantiate(simdModule, imports) }),
    async (imports) => ({ module: nonSimdModule, instance: await WebAssembly.instantiate(nonSimdModule, imports) }),
  );
  derivePasswordHash = (input) => derive(input as Argon2idParams);
  passwordRecord = await hashPassword(testPassword, derivePasswordHash);
  const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
  signingKey = pair.privateKey;
  publicJwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey, kid: "dreyzestore-test-key" };
});

function createD1(connection: DatabaseSync): D1Database {
  const d1 = {
    prepare(query: string) {
      const statement = connection.prepare(query);
      let bound: unknown[] = [];
      const prepared = {
        bind(...values: unknown[]) { bound = values; return prepared; },
        async all<T = Record<string, unknown>>() {
          return { results: statement.all(...(bound as never[])) as T[], success: true, meta: {} };
        },
        async first<T = Record<string, unknown>>() {
          return (statement.get(...(bound as never[])) as T | undefined) ?? null;
        },
        async run() {
          const result = statement.run(...(bound as never[]));
          return { success: true, meta: { changes: Number(result.changes), last_row_id: Number(result.lastInsertRowid) } };
        },
      };
      return prepared;
    },
    async batch(statements: D1PreparedStatement[]) {
      connection.exec("BEGIN IMMEDIATE");
      try {
        const results = [];
        for (const statement of statements) results.push(await statement.run());
        connection.exec("COMMIT");
        return results;
      } catch (error) {
        connection.exec("ROLLBACK");
        throw error;
      }
    },
  };
  return d1 as unknown as D1Database;
}

interface MemoryObject {
  bytes: Uint8Array;
  etag: string;
  httpMetadata?: R2HTTPMetadata;
  customMetadata?: Record<string, string>;
}

class MemoryBucket {
  readonly objects = new Map<string, MemoryObject>();

  async put(key: string, value: Uint8Array | ArrayBuffer | ReadableStream | string, options?: R2PutOptions) {
    let bytes: Uint8Array;
    if (value instanceof Uint8Array) bytes = new Uint8Array(value);
    else if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
    else if (typeof value === "string") bytes = new TextEncoder().encode(value);
    else bytes = await consume(value as ReadableStream<Uint8Array>);
    const etag = createHash("sha256").update(bytes).digest("hex");
    const httpMetadata = options?.httpMetadata instanceof Headers ? undefined : options?.httpMetadata;
    this.objects.set(key, { bytes, etag, httpMetadata, customMetadata: options?.customMetadata });
    return { key, size: bytes.byteLength, etag, version: "test-version", checksums: {}, httpMetadata, customMetadata: options?.customMetadata };
  }

  async head(key: string) {
    const object = this.objects.get(key);
    if (!object) return null;
    return { key, size: object.bytes.byteLength, etag: object.etag, version: "test-version", checksums: {}, httpMetadata: object.httpMetadata, customMetadata: object.customMetadata };
  }

  async get(key: string, options?: R2GetOptions) {
    const object = this.objects.get(key);
    if (!object) return null;
    const etagCondition = options?.onlyIf && !(options.onlyIf instanceof Headers) && "etagMatches" in options.onlyIf
      ? options.onlyIf.etagMatches : undefined;
    if (etagCondition && etagCondition !== object.etag) return null;
    const bytes = new Uint8Array(object.bytes);
    const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(bytes); controller.close(); } });
    return {
      key,
      size: bytes.byteLength,
      etag: object.etag,
      version: "test-version",
      checksums: {},
      httpMetadata: object.httpMetadata,
      customMetadata: object.customMetadata,
      body,
      async arrayBuffer() { return bytes.slice().buffer; },
      async text() { return new TextDecoder().decode(bytes); },
      async json<T>() { return JSON.parse(new TextDecoder().decode(bytes)) as T; },
      async blob() { return new Blob([bytes]); },
    };
  }

  async delete(key: string | string[]) {
    for (const item of Array.isArray(key) ? key : [key]) this.objects.delete(item);
  }
}

async function consume(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const next = await reader.read();
    if (next.done) break;
    chunks.push(next.value);
    length += next.value.byteLength;
  }
  const output = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.byteLength; }
  return output;
}

beforeEach(() => {
  database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys = ON");
  for (const file of readdirSync(migrationDirectory).filter((name) => name.endsWith(".sql")).sort()) {
    database.exec(readFileSync(resolve(migrationDirectory, file), "utf8"));
  }
  database.exec(readFileSync(seedPath, "utf8"));
  staging = new MemoryBucket();
  published = new MemoryBucket();
  environment = {
    DB: createD1(database),
    PASSWORD_KDF: createTestPasswordKdfNamespace() as DurableObjectNamespace,
    STAGING_ASSETS: staging as unknown as R2Bucket,
    PUBLIC_ASSETS: published as unknown as R2Bucket,
    ADMIN_ORIGINS: "http://localhost:5173",
    PUBLIC_ASSETS_BASE_URL: "https://cdn.example.invalid",
    PUBLIC_API_BASE_URL: "https://api.example.invalid",
    PUBLIC_BUCKET_NAME: "test-public-assets",
    STAGING_BUCKET_NAME: "test-private-staging",
    R2_ACCOUNT_ID: "0123456789abcdef0123456789abcdef",
    R2_ACCESS_KEY_ID: "unit-test-access-key",
    R2_SECRET_ACCESS_KEY: "unit-test-secret-key",
    GITHUB_OWNER: "faridikdev",
    GITHUB_REPOSITORY: "DreyzeStore",
    GITHUB_VALIDATOR_WORKFLOW: "validate-ipa.yml",
    GITHUB_VALIDATOR_REF: "main",
    VALIDATOR_API_BASE_URL: "http://127.0.0.1:8787",
    VALIDATOR_OIDC_AUDIENCE: oidcAudience,
    VALIDATOR_OIDC_JWKS_URL: "https://token.actions.githubusercontent.com/.well-known/jwks",
    ADMIN_CSRF_SECRET: "admin-csrf-secret-for-tests-32bytes",
    ADMIN_RATE_LIMIT_HMAC_KEY: "admin-rate-limit-secret-tests-32bytes",
    SECURE_COOKIES: "false",
    LOCAL_UPLOADS_ENABLED: "true",
    LOCAL_VALIDATOR_ENABLED: "true",
    TEST_FETCH: async () => new Response(JSON.stringify({ keys: [publicJwk] }), { headers: { "Content-Type": "application/json" } }),
  };
  database.prepare("INSERT INTO admin_users (id, provider, subject, role) VALUES (?, 'password', ?, 'admin')")
    .run("admin-test", "operator@example.test");
  database.prepare(
    "INSERT INTO admin_password_credentials (admin_user_id, password_hash, password_salt, algorithm, iterations, memory_kib, parallelism) VALUES (?, ?, ?, ?, ?, ?, ?)",
  ).run("admin-test", passwordRecord.hash, passwordRecord.salt, passwordRecord.algorithm, passwordRecord.iterations, passwordRecord.memoryKiB, passwordRecord.parallelism);
});

function createTestPasswordKdfNamespace(): object {
  return {
    idFromName(name: string) { return { name }; },
    get() {
      return {
        async fetch(_input: RequestInfo | URL, init?: RequestInit) {
          const body = JSON.parse(String(init?.body ?? "{}")) as { password: string; credential: PasswordHash };
          const result = await verifyPasswordRecord(body.password, body.credential, derivePasswordHash);
          return Response.json(result, { headers: { "Cache-Control": "no-store" } });
        },
      };
    },
  };
}

afterEach(() => database.close());

interface AuthContext { cookie: string; csrf: string }

async function request(path: string, options: RequestInit = {}, requestEnvironment = environment): Promise<Response> {
  return app.request(path, options, requestEnvironment);
}

async function signIn(email = "operator@example.test", password = testPassword): Promise<{ response: Response; auth?: AuthContext }> {
  const response = await request("/api/v1/admin/auth/login", {
    method: "POST",
    headers: { Origin: "http://localhost:5173", "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.14" },
    body: JSON.stringify({ email, password }),
  });
  if (!response.ok) return { response };
  const body = await response.json() as { data: { csrfToken: string } };
  const setCookie = response.headers.get("set-cookie") ?? "";
  return { response, auth: { cookie: setCookie.split(";", 1)[0]!, csrf: body.data.csrfToken } };
}

function adminHeaders(auth: AuthContext, json = true): Headers {
  const headers = new Headers({ Cookie: auth.cookie, Origin: "http://localhost:5173", "X-CSRF-Token": auth.csrf });
  if (json) headers.set("Content-Type", "application/json");
  return headers;
}

async function adminJson<T>(auth: AuthContext, path: string, method: string, value: unknown): Promise<{ response: Response; body: T }> {
  const response = await request(path, { method, headers: adminHeaders(auth), body: JSON.stringify(value) });
  return { response, body: await response.json() as T };
}

async function createValidatorJWT(overrides: Record<string, unknown> = {}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "dreyzestore-test-key" }));
  const claims = {
    iss: "https://token.actions.githubusercontent.com",
    aud: oidcAudience,
    iat: now,
    nbf: now - 5,
    exp: now + 300,
    repository: "faridikdev/DreyzeStore",
    ref: "refs/heads/main",
    event_name: "workflow_dispatch",
    workflow_ref: "faridikdev/DreyzeStore/.github/workflows/validate-ipa.yml@refs/heads/main",
    run_id: "2345678901",
    run_attempt: "1",
    ...overrides,
  };
  const payload = base64url(JSON.stringify(claims));
  const input = header + "." + payload;
  const signed = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", signingKey, new TextEncoder().encode(input)));
  const signature = bytesToBase64Url(signed);
  return input + "." + signature;
}

function bytesToBase64Url(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function base64url(value: string): string {
  return Buffer.from(value, "utf8").toString("base64url");
}

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const value of bytes) {
    crc ^= value;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function generatedIPA(bundleIdentifier = "org.dreyze.releasefixture"): Uint8Array {
  const plist = new TextEncoder().encode(
    `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>` +
    `<key>CFBundleIdentifier</key><string>${bundleIdentifier}</string>` +
    `<key>CFBundleShortVersionString</key><string>1.2.0</string>` +
    `<key>CFBundleVersion</key><string>12</string>` +
    `<key>MinimumOSVersion</key><string>16.0</string>` +
    `<key>CFBundleExecutable</key><string>Fixture</string>` +
    `<key>CFBundleDisplayName</key><string>Release Fixture</string>` +
    `</dict></plist>`,
  );
  return zipStored([
    ["Payload/Fixture.app/Info.plist", plist, false],
    ["Payload/Fixture.app/Fixture", new TextEncoder().encode("safe generated app executable bytes"), true],
  ]);
}

function zipStored(entries: Array<[string, Uint8Array, boolean]>): Uint8Array {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const [name, data, executable] of entries) {
    const filename = Buffer.from(name, "utf8");
    const crc = crc32(data);
    const local = Buffer.alloc(30 + filename.length);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(0, 8); local.writeUInt32LE(crc, 14); local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22); local.writeUInt16LE(filename.length, 26); filename.copy(local, 30);
    locals.push(local, Buffer.from(data));
    const central = Buffer.alloc(46 + filename.length);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(0x0314, 4); central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x800, 8); central.writeUInt16LE(0, 10); central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20); central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(filename.length, 28); central.writeUInt32LE((executable ? 0o100755 : 0o100644) * 65536, 38);
    central.writeUInt32LE(offset, 42); filename.copy(central, 46); centrals.push(central);
    offset += local.length + data.length;
  }
  const centralOffset = offset;
  const centralSize = centrals.reduce((total, part) => total + part.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12); end.writeUInt32LE(centralOffset, 16);
  return new Uint8Array(Buffer.concat([...locals, ...centrals, end]));
}

function pngChunk(type: string, bytes: Uint8Array): Buffer {
  const typeBytes = Buffer.from(type, "ascii");
  const chunk = Buffer.alloc(12 + bytes.length);
  chunk.writeUInt32BE(bytes.length, 0); typeBytes.copy(chunk, 4); Buffer.from(bytes).copy(chunk, 8);
  chunk.writeUInt32BE(crc32(new Uint8Array(Buffer.concat([typeBytes, Buffer.from(bytes)]))), 8 + bytes.length);
  return chunk;
}

function generatedPNG(size: number): Uint8Array {
  const header = Buffer.alloc(13); header.writeUInt32BE(size, 0); header.writeUInt32BE(size, 4);
  header[8] = 8; header[9] = 6; header[10] = 0; header[11] = 0; header[12] = 0;
  const rows = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y += 1) { rows[y * (size * 4 + 1)] = 0; for (let x = 0; x < size; x += 1) rows[y * (size * 4 + 1) + 1 + x * 4 + 3] = 255; }
  const compressed = new Uint8Array(deflateSync(rows));
  return new Uint8Array(Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), pngChunk("IHDR", header), pngChunk("IDAT", compressed), pngChunk("IEND", new Uint8Array())]));
}

describe("admin authentication and publish pipeline", () => {
  it("rejects invalid passwords and protects admin routes", async () => {
    const wrong = await signIn("operator@example.test", "wrong-password");
    expect(wrong.response.status).toBe(401);
    expect((await request("/api/v1/admin/dashboard")).status).toBe(401);
    const fake = await request("/api/v1/validator/uploads/00000000-0000-0000-0000-000000000001/lease", {
      method: "POST", headers: { Authorization: "Bearer " + await createValidatorJWT({ repository: "attacker/repo" }), "Content-Type": "application/json" }, body: JSON.stringify({ dispatchTicket: "x".repeat(43) }),
    });
    expect(fake.status).toBe(401);
  });

  it("rejects missing and invalid CSRF tokens for state changes", async () => {
    const login = await signIn();
    expect(login.auth).toBeDefined();
    const noToken = await request("/api/v1/admin/apps", {
      method: "POST", headers: { Cookie: login.auth!.cookie, Origin: "http://localhost:5173", "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(noToken.status).toBe(403);
    const invalid = await request("/api/v1/admin/apps", {
      method: "POST", headers: { ...Object.fromEntries(adminHeaders(login.auth!).entries()), "X-CSRF-Token": "invalid" }, body: "{}",
    });
    expect(invalid.status).toBe(403);
  });

  it("denies editor accounts the administrator-only delete and publish operations", async () => {
    database.prepare("INSERT INTO admin_users (id, provider, subject, role) VALUES (?, 'password', ?, 'editor')")
      .run("editor-test", "editor@example.test");
    database.prepare(
      "INSERT INTO admin_password_credentials (admin_user_id, password_hash, password_salt, algorithm, iterations, memory_kib, parallelism) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).run("editor-test", passwordRecord.hash, passwordRecord.salt, passwordRecord.algorithm, passwordRecord.iterations, passwordRecord.memoryKiB, passwordRecord.parallelism);
    const login = await signIn("editor@example.test");
    expect(login.auth).toBeDefined();
    const remove = await request("/api/v1/admin/apps/app-aurora-notes", {
      method: "DELETE", headers: adminHeaders(login.auth!), body: JSON.stringify({ confirm: true }),
    });
    const publish = await request("/api/v1/admin/uploads/00000000-0000-0000-0000-000000000001/publish", {
      method: "POST", headers: adminHeaders(login.auth!), body: JSON.stringify({ confirmRights: true }),
    });
    expect(remove.status).toBe(403);
    expect(publish.status).toBe(403);
    expect(database.prepare("SELECT deleted_at FROM apps WHERE id = 'app-aurora-notes'").get()).toMatchObject({ deleted_at: null });
  });

  it("limits repeated login attempts and audits them without storing raw email tokens", async () => {
    let response: Response | undefined;
    for (let attempt = 0; attempt < 6; attempt += 1) response = (await signIn("operator@example.test", "incorrect" )).response;
    expect(response?.status).toBe(429);
    const audit = database.prepare("SELECT action, actor_subject FROM audit_logs WHERE action = 'login.rate_limited' LIMIT 1").get() as { action: string; actor_subject: string };
    expect(audit.action).toBe("login.rate_limited");
    expect(audit.actor_subject).not.toContain("operator@example.test");
  });

  it("revokes an expired session instead of accepting its cookie", async () => {
    const raw = "a".repeat(43);
    const tokenHash = createHash("sha256").update(raw).digest("hex");
    database.prepare("INSERT INTO admin_sessions (token_sha256, admin_user_id, csrf_sha256, expires_at) VALUES (?, ?, ?, ?)")
      .run(tokenHash, "admin-test", "0".repeat(64), "2000-01-01T00:00:00.000Z");
    const response = await request("/api/v1/admin/dashboard", { headers: { Cookie: "dreyzestore_session=" + raw } });
    expect(response.status).toBe(401);
    expect(database.prepare("SELECT revoked_at FROM admin_sessions WHERE token_sha256 = ?").get(tokenHash)).toMatchObject({ revoked_at: expect.any(String) });
  });

  it("requires HTTPS admin origins and returns same-site session cookies", async () => {
    const response = await request("/api/v1/admin/auth/login", {
      method: "POST", headers: { Origin: "https://attacker.example", "Content-Type": "application/json" },
      body: JSON.stringify({ email: "operator@example.test", password: testPassword }),
    });
    expect(response.status).toBe(403);
    const accepted = await signIn();
    expect(accepted.response.status).toBe(200);
    expect(accepted.response.headers.get("set-cookie")).toContain("HttpOnly");
    expect(accepted.response.headers.get("set-cookie")).toContain("SameSite=Lax");
  });

  it("defaults session cookies to Secure unless local mode explicitly opts out", async () => {
    const productionLikeEnvironment = { ...environment };
    delete productionLikeEnvironment.SECURE_COOKIES;
    const productionResponse = await request("/api/v1/admin/auth/login", {
      method: "POST", headers: { Origin: "http://localhost:5173", "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.15" },
      body: JSON.stringify({ email: "operator@example.test", password: testPassword }),
    }, productionLikeEnvironment);
    expect(productionResponse.status).toBe(200);
    expect(productionResponse.headers.get("set-cookie")).toContain("Secure");
    expect(productionResponse.headers.get("set-cookie")).toContain("__Host-dreyzestore_session");
  });

  it("performs a real generated IPA upload, Python validation, review, attestation, publish, and public download", async () => {
    const login = await signIn();
    expect(login.response.status).toBe(200);
    const auth = login.auth!;
    const created = await adminJson<{ data: { id: string } }>(auth, "/api/v1/admin/apps", "POST", {
      name: "Release Fixture", bundleIdentifier: "org.dreyze.releasefixture", developer: "Dreyze Test Lab",
      categoryId: "utilities", description: "Generated test metadata for the authorized publication test.",
      shortDescription: "Generated package fixture for integration tests.", repositoryId: "repo-dreyze-dev",
    });
    expect(created.response.status).toBe(201);
    const appId = created.body.data.id;
    expect(database.prepare("SELECT published FROM apps WHERE id = ?").get(appId)).toMatchObject({ published: 0 });
    expect((await request(`/api/v1/apps/${appId}`)).status).toBe(404);
    const hiddenSearch = await request(`/api/v1/search?q=${encodeURIComponent("Release Fixture")}`);
    expect(hiddenSearch.status).toBe(200);
    expect((await hiddenSearch.json() as { data: unknown[] }).data).toEqual([]);

    const icon = generatedPNG(64);
    const assetSession = await adminJson<{ data: { id: string; uploadURL: string } }>(auth, `/api/v1/admin/apps/${appId}/assets`, "POST", {
      kind: "icon", size: icon.byteLength, contentType: "image/png",
    });
    const assetPath = new URL(assetSession.body.data.uploadURL).pathname;
    const imageResponse = await request(assetPath, {
      method: "PUT", headers: { ...Object.fromEntries(adminHeaders(auth, false).entries()), "Content-Type": "image/png", "Content-Length": String(icon.byteLength) }, body: Buffer.from(icon),
    });
    expect(imageResponse.status).toBe(200);
    expect((await request(`/api/v1/admin/assets/${assetSession.body.data.id}/complete`, {
      method: "POST", headers: adminHeaders(auth),
    })).status).toBe(200);

    const ipa = generatedIPA();
    const packageSession = await adminJson<{ data: { id: string; uploadURL: string } }>(auth, `/api/v1/admin/apps/${appId}/uploads`, "POST", { size: ipa.byteLength });
    expect(packageSession.response.status).toBe(201);
    const prematurePublish = await adminJson<{ error: { code: string } }>(auth, `/api/v1/admin/uploads/${packageSession.body.data.id}/publish`, "POST", { confirmRights: true });
    expect(prematurePublish.response.status).toBe(409);
    expect(prematurePublish.body.error.code).toBe("release_not_reviewable");
    const uploadPath = new URL(packageSession.body.data.uploadURL).pathname;
    const fileResponse = await request(uploadPath, {
      method: "PUT", headers: { ...Object.fromEntries(adminHeaders(auth, false).entries()), "Content-Type": "application/octet-stream", "Content-Length": String(ipa.byteLength) }, body: Buffer.from(ipa),
    });
    expect(fileResponse.status).toBe(200);
    const completion = await adminJson<{ data: { state: string; dispatchTicket: string } }>(auth, `/api/v1/admin/uploads/${packageSession.body.data.id}/complete`, "POST", {});
    expect(completion.body.data.state).toBe("queued");

    const leaseResponse = await request(`/api/v1/validator/uploads/${packageSession.body.data.id}/lease`, {
      method: "POST", headers: { Authorization: "Bearer " + await createValidatorJWT(), "Content-Type": "application/json" }, body: JSON.stringify({ dispatchTicket: completion.body.data.dispatchTicket }),
    });
    expect(leaseResponse.status, await leaseResponse.clone().text()).toBe(200);
    const lease = (await leaseResponse.json() as { data: { reportNonce: string } }).data;
    const staged = staging.objects.get(`staging/${packageSession.body.data.id}/package.ipa`)!;
    const temporary = mkdtempSync(join(tmpdir(), "dreyzestore-e2e-"));
    const localPackage = join(temporary, "generated-test-fixture.ipa");
    try {
      writeFileSync(localPackage, staged.bytes);
      const executable = process.platform === "win32" ? "python" : "python3";
      const validation = spawnSync(executable, [validatorPath, localPackage], { cwd: rootDirectory, encoding: "utf8" });
      expect(validation.status).toBe(0);
      const report = JSON.parse(validation.stdout) as Record<string, unknown>;
      expect(report["sha256"]).toBe(createHash("sha256").update(ipa).digest("hex"));
      const accepted = await request(`/api/v1/validator/uploads/${packageSession.body.data.id}/result`, {
        method: "POST", headers: { Authorization: "Bearer " + await createValidatorJWT(), "Content-Type": "application/json" },
        body: JSON.stringify({ reportNonce: lease.reportNonce, ...report }),
      });
      expect(accepted.status).toBe(200);
      expect(await accepted.json()).toMatchObject({ data: { state: "ready_for_review", metadataMatches: true } });
    } finally { rmSync(temporary, { recursive: true, force: true }); }

    const review = await adminJson<{ data: { state: string } }>(auth, `/api/v1/admin/uploads/${packageSession.body.data.id}`, "PATCH", {
      releaseNotes: "Generated end-to-end release fixture.", channel: "stable",
    });
    expect(review.response.status).toBe(200);
    const noRights = await adminJson<{ error: { code: string } }>(auth, `/api/v1/admin/uploads/${packageSession.body.data.id}/publish`, "POST", { confirmRights: false });
    expect(noRights.response.status).toBe(400);
    expect(noRights.body.error.code).toBe("rights_attestation_required");
    const publishedRelease = await adminJson<{ data: { state: string; sha256: string; version: string } }>(
      auth, `/api/v1/admin/uploads/${packageSession.body.data.id}/publish`, "POST", { confirmRights: true },
    );
    expect(publishedRelease.response.status).toBe(201);
    expect(publishedRelease.body.data).toMatchObject({ state: "published", version: "1.2.0" });
    expect(staging.objects.has(`staging/${packageSession.body.data.id}/package.ipa`)).toBe(false);

    const detailsResponse = await request(`/api/v1/apps/${appId}`);
    expect(detailsResponse.status).toBe(200);
    const details = (await detailsResponse.json() as { data: { currentVersion: { downloadURL: string; sha256: string; size: number } } }).data;
    expect(details.currentVersion.sha256).toBe(publishedRelease.body.data.sha256);
    expect(details.currentVersion.size).toBe(ipa.byteLength);
    const downloadKey = decodeURIComponent(new URL(details.currentVersion.downloadURL).pathname).replace(/^\//u, "");
    const packageObject = published.objects.get(downloadKey);
    expect(packageObject).toBeDefined();
    expect(createHash("sha256").update(packageObject!.bytes).digest("hex")).toBe(details.currentVersion.sha256);
    const repositoryResponse = await request("/api/v1/repository");
    const manifest = await repositoryResponse.json() as never;
    expect(repositoryResponse.status).toBe(200);
    expect(validateRepository(manifest)).toMatchObject({ valid: true });
    expect(JSON.stringify(manifest)).not.toContain("published_object_key");
    expect(database.prepare("SELECT confirmed, admin_user_id, release_id, attestation_version FROM distribution_rights_attestations WHERE upload_id = ?")
      .get(packageSession.body.data.id)).toMatchObject({ confirmed: 1, admin_user_id: "admin-test", attestation_version: "v1" });
  });

  it("blocks publication without a matching validator identity and exact bundle metadata", async () => {
    const login = await signIn(); const auth = login.auth!;
    const created = await adminJson<{ data: { id: string } }>(auth, "/api/v1/admin/apps", "POST", {
      name: "Mismatch Fixture", bundleIdentifier: "org.dreyze.expected", developer: "Dreyze Test Lab",
      categoryId: "utilities", description: "Fixture.", shortDescription: "Bundle mismatch fixture.", repositoryId: "repo-dreyze-dev",
    });
    const id = created.body.data.id;
    const ipa = generatedIPA("org.dreyze.actual");
    const session = await adminJson<{ data: { id: string; uploadURL: string } }>(auth, `/api/v1/admin/apps/${id}/uploads`, "POST", { size: ipa.length });
    const localPath = new URL(session.body.data.uploadURL).pathname;
    await request(localPath, { method: "PUT", headers: { ...Object.fromEntries(adminHeaders(auth, false).entries()), "Content-Type": "application/octet-stream", "Content-Length": String(ipa.length) }, body: Buffer.from(ipa) });
    const completion = await adminJson<{ data: { dispatchTicket: string } }>(auth, `/api/v1/admin/uploads/${session.body.data.id}/complete`, "POST", {});
    const lease = await request(`/api/v1/validator/uploads/${session.body.data.id}/lease`, {
      method: "POST", headers: { Authorization: "Bearer " + await createValidatorJWT(), "Content-Type": "application/json" }, body: JSON.stringify({ dispatchTicket: completion.body.data.dispatchTicket }),
    });
    const nonce = (await lease.json() as { data: { reportNonce: string } }).data.reportNonce;
    const report = { result: "passed", reportNonce: nonce, bundleIdentifier: "org.dreyze.actual", version: "1.2.0", build: "12", minimumOS: "16.0", displayName: "Fixture", size: ipa.length, sha256: createHash("sha256").update(ipa).digest("hex") };
    const response = await request(`/api/v1/validator/uploads/${session.body.data.id}/result`, {
      method: "POST", headers: { Authorization: "Bearer " + await createValidatorJWT(), "Content-Type": "application/json" }, body: JSON.stringify(report),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ data: { state: "validation_failed", metadataMatches: false } });
    const publishAttempt = await adminJson<{ error: { code: string } }>(auth, `/api/v1/admin/uploads/${session.body.data.id}/publish`, "POST", { confirmRights: true });
    expect(publishAttempt.response.status).toBe(409);
    expect(publishAttempt.body.error.code).toBe("release_not_reviewable");
    expect((await request(`/api/v1/apps/${id}`)).status).toBe(404);
    const rejected = await adminJson<{ data: { state: string } }>(auth, `/api/v1/admin/uploads/${session.body.data.id}/reject`, "POST", { confirm: true });
    expect(rejected.response.status).toBe(200);
    expect(rejected.body.data.state).toBe("rejected");
    expect(staging.objects.has(`staging/${session.body.data.id}/package.ipa`)).toBe(false);
    expect((await request(`/api/v1/apps/${id}`)).status).toBe(404);
  });

  it("rejects images whose bytes do not match their declared format", async () => {
    const login = await signIn(); const auth = login.auth!;
    const created = await adminJson<{ data: { id: string } }>(auth, "/api/v1/admin/apps", "POST", {
      name: "Invalid Image Fixture", bundleIdentifier: "org.dreyze.invalidimage", developer: "Dreyze Test Lab",
      categoryId: "utilities", description: "Fixture.", shortDescription: "Invalid image bytes.", repositoryId: "repo-dreyze-dev",
    });
    const appId = created.body.data.id;
    const invalid = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]);
    const session = await adminJson<{ data: { id: string; uploadURL: string } }>(auth, `/api/v1/admin/apps/${appId}/assets`, "POST", {
      kind: "icon", size: invalid.byteLength, contentType: "image/png",
    });
    const path = new URL(session.body.data.uploadURL).pathname;
    expect((await request(path, {
      method: "PUT", headers: { ...Object.fromEntries(adminHeaders(auth, false).entries()), "Content-Type": "image/png", "Content-Length": String(invalid.byteLength) }, body: Buffer.from(invalid),
    })).status).toBe(200);
    const complete = await request(`/api/v1/admin/assets/${session.body.data.id}/complete`, { method: "POST", headers: adminHeaders(auth) });
    expect(complete.status).toBe(422);
    expect(published.objects.size).toBe(0);
  });

  it("rejects oversized package sessions and malformed app metadata", async () => {
    const login = await signIn(); const auth = login.auth!;
    const oversized = await adminJson<{ error: { code: string } }>(auth, "/api/v1/admin/apps/app-aurora-notes/uploads", "POST", { size: 1_073_741_825 });
    expect(oversized.response.status).toBe(413);
    const malformed = await adminJson<{ error: { code: string } }>(auth, "/api/v1/admin/apps", "POST", { name: null });
    expect(malformed.response.status).toBe(400);
  });
});
