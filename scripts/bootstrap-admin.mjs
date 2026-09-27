import setupWasm from "argon2id/lib/setup.js";
import { randomBytes, randomUUID } from "node:crypto";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const suppliedArgs = process.argv.slice(2);
const remote = suppliedArgs.includes("--remote");
const local = suppliedArgs.includes("--local");
if (remote === local) throw new Error("Specify exactly one of --local or --remote.");

const emailArg = suppliedArgs.find((arg) => arg.startsWith("--email="))?.slice("--email=".length);
const email = (emailArg ?? await ask("Admin email: ")).trim().toLowerCase();
if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(email)) {
  throw new Error("Enter a valid email address.");
}

const password = randomBytes(32).toString("base64url");
const salt = randomBytes(32);
const wasmSetupPath = fileURLToPath(import.meta.resolve("argon2id/lib/setup.js"));
const packageDirectory = resolve(wasmSetupPath, "..", "..");
const [simdBytes, nonSimdBytes] = await Promise.all([
  readFile(join(packageDirectory, "dist", "simd.wasm")),
  readFile(join(packageDirectory, "dist", "no-simd.wasm")),
]);
const simdModule = await WebAssembly.compile(simdBytes);
const nonSimdModule = await WebAssembly.compile(nonSimdBytes);
const derive = await setupWasm(
  async (imports) => ({ module: simdModule, instance: await WebAssembly.instantiate(simdModule, imports) }),
  async (imports) => ({ module: nonSimdModule, instance: await WebAssembly.instantiate(nonSimdModule, imports) }),
);
const hash = derive({ password: Buffer.from(password), salt, parallelism: 1, passes: 2, memorySize: 19_456, tagLength: 32 });
const adminId = "admin-" + randomUUID();
const quote = (value) => "'" + value.replaceAll("'", "''") + "'";
const targetDatabase = suppliedArgs.find((arg) => arg.startsWith("--database="))?.slice("--database=".length) ?? "dreyzestore-local";
if (!/^[A-Za-z0-9_-]{1,64}$/u.test(targetDatabase)) throw new Error("The D1 database name is invalid.");
if (remote) {
  const confirmation = await ask(`Type the exact D1 database name to confirm remote bootstrap (${targetDatabase}): `);
  if (confirmation !== targetDatabase) throw new Error("Remote bootstrap confirmation did not match.");
}
const sql = [
  "INSERT INTO admin_users (id, provider, subject, role, enabled) SELECT " +
    [adminId, "password", email, "admin"].map(quote).join(", ") + ", 1 " +
    "WHERE NOT EXISTS (SELECT 1 FROM admin_users WHERE provider = 'password' AND enabled = 1 AND role = 'admin');",
  "INSERT INTO admin_password_credentials (admin_user_id, password_hash, password_salt, algorithm, iterations, memory_kib, parallelism) " +
    "SELECT " + [adminId, Buffer.from(hash).toString("hex"), salt.toString("hex"), "argon2id-v1"].map(quote).join(", ") + ", 2, 19456, 1 " +
    "WHERE EXISTS (SELECT 1 FROM admin_users WHERE id = " + quote(adminId) + " AND enabled = 1 AND role = 'admin');",
  "SELECT CASE WHEN EXISTS (SELECT 1 FROM admin_password_credentials WHERE admin_user_id = " + quote(adminId) +
    ") THEN 'dreyzestore_admin_bootstrap_created' ELSE 'dreyzestore_admin_bootstrap_not_created' END AS bootstrap_result;",
].join("\n");

const tempDirectory = await mkdtemp(join(tmpdir(), "dreyzestore-admin-bootstrap-"));
const sqlPath = join(tempDirectory, "bootstrap.sql");
try {
  await writeFile(sqlPath, sql, { encoding: "utf8", mode: 0o600, flag: "wx" });
  if (process.platform !== "win32") await chmod(sqlPath, 0o600);
  const executable = process.platform === "win32" ? "npx.cmd" : "npx";
  const command = ["wrangler", "d1", "execute", targetDatabase];
  if (local) command.push("--local"); else command.push("--remote");
  command.push(
    "--config", "backend/wrangler.jsonc", "--file", sqlPath,
  );
  const result = spawnSync(executable, command, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (result.status !== 0) {
    throw new Error("D1 bootstrap failed. Check the selected database and apply migrations first.");
  }
  if (!result.stdout.includes("dreyzestore_admin_bootstrap_created")) {
    throw new Error("No first administrator was created. An enabled administrator may already exist; the generated password was discarded.");
  }
  process.stdout.write(result.stdout);
  process.stdout.write("\nAdmin account created. Copy this one-time generated password now:\n");
  process.stdout.write("Email: " + email + "\nPassword: " + password + "\n");
  process.stdout.write("The plaintext password is not saved by this script. Store it in your approved password manager.\n");
} finally {
  await rm(tempDirectory, { recursive: true, force: true });
}

async function ask(prompt) {
  const { createInterface } = await import("node:readline/promises");
  const terminal = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return await terminal.question(prompt);
  } finally {
    terminal.close();
  }
}
