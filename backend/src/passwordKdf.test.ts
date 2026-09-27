import { pbkdf2Sync, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import setupWasm, { type Argon2idParams } from "argon2id/lib/setup.js";
import { hashPassword, isPasswordHash, PASSWORD_HASH_ALGORITHM, PASSWORD_HASH_MEMORY_KIB, PASSWORD_HASH_PASSES, verifyPasswordRecord, type Argon2idDerive, type PasswordHash } from "./security/passwordKdfCore.js";

let derive: Argon2idDerive;

beforeAll(async () => {
  const libraryDirectory = dirname(fileURLToPath(import.meta.resolve("argon2id/lib/setup.js")));
  const simdModule = await WebAssembly.compile(readFileSync(resolve(libraryDirectory, "../dist/simd.wasm")));
  const nonSimdModule = await WebAssembly.compile(readFileSync(resolve(libraryDirectory, "../dist/no-simd.wasm")));
  const compute = await setupWasm(
    async (imports) => ({ module: simdModule, instance: await WebAssembly.instantiate(simdModule, imports) }),
    async (imports) => ({ module: nonSimdModule, instance: await WebAssembly.instantiate(nonSimdModule, imports) }),
  );
  derive = (input) => compute(input as Argon2idParams);
});

describe("admin password KDF", () => {
  it("creates and verifies an Argon2id v1 credential with fixed parameters", async () => {
    const credential = await hashPassword("correct horse battery staple", derive);
    expect(credential.algorithm).toBe(PASSWORD_HASH_ALGORITHM);
    expect(credential.iterations).toBe(PASSWORD_HASH_PASSES);
    expect(credential.memoryKiB).toBe(PASSWORD_HASH_MEMORY_KIB);
    expect(credential.parallelism).toBe(1);
    expect(isPasswordHash(credential)).toBe(true);
    expect((await verifyPasswordRecord("correct horse battery staple", credential, derive)).verified).toBe(true);
    expect((await verifyPasswordRecord("wrong password", credential, derive)).verified).toBe(false);
  });

  it("verifies a bounded legacy PBKDF2 record and returns a fresh Argon2id hash", async () => {
    const password = "phase-six-local-bootstrap-credential";
    const salt = randomBytes(32);
    const digest = pbkdf2Sync(password, salt, 600_000, 32, "sha256");
    const legacy: PasswordHash = {
      algorithm: "PBKDF2-HMAC-SHA256",
      iterations: 600_000,
      memoryKiB: PASSWORD_HASH_MEMORY_KIB,
      parallelism: 1,
      salt: bytesToHex(salt),
      hash: bytesToHex(digest),
    };
    const result = await verifyPasswordRecord(password, legacy, derive);
    expect(result.verified).toBe(true);
    expect(result.upgraded?.algorithm).toBe(PASSWORD_HASH_ALGORITHM);
    expect(result.upgraded?.salt).not.toBe(legacy.salt);
    expect((await verifyPasswordRecord(password, result.upgraded!, derive)).verified).toBe(true);
  }, 20_000);

  it("rejects attacker-controlled KDF parameters and malformed records", async () => {
    const valid = await hashPassword("password", derive);
    expect(isPasswordHash({ ...valid, memoryKiB: Number.MAX_SAFE_INTEGER })).toBe(false);
    expect(isPasswordHash({ ...valid, iterations: 500_000 })).toBe(false);
    expect(isPasswordHash({ ...valid, extra: "field" })).toBe(false);
    expect((await verifyPasswordRecord("password", { ...valid, parallelism: 100 }, derive)).verified).toBe(false);
  });
});

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}
