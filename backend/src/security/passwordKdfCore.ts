import { createHmac } from "node:crypto";
import { fromHex, randomBytes, toHex } from "./crypto.js";

export const PASSWORD_HASH_ALGORITHM = "argon2id-v1" as const;
export const PASSWORD_HASH_PASSES = 2;
export const PASSWORD_HASH_MEMORY_KIB = 19_456;
export const PASSWORD_HASH_PARALLELISM = 1;
const PASSWORD_HASH_BYTES = 32;
const LEGACY_PBKDF2_MIN = 600_000;
const LEGACY_PBKDF2_MAX = 1_200_000;
const encoder = new TextEncoder();

export interface PasswordHash {
  algorithm: typeof PASSWORD_HASH_ALGORITHM | "PBKDF2-HMAC-SHA256";
  iterations: number;
  memoryKiB: number;
  parallelism: number;
  salt: string;
  hash: string;
}

export function isPasswordHash(value: unknown): value is PasswordHash {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some((key) => !["algorithm", "iterations", "memoryKiB", "parallelism", "salt", "hash"].includes(key))) return false;
  if (typeof record["salt"] !== "string" || !/^[a-f0-9]{64}$/iu.test(record["salt"]) ||
      typeof record["hash"] !== "string" || !/^[a-f0-9]{64}$/iu.test(record["hash"]) ||
      !Number.isSafeInteger(record["iterations"]) || record["memoryKiB"] !== PASSWORD_HASH_MEMORY_KIB || record["parallelism"] !== 1) return false;
  if (record["algorithm"] === PASSWORD_HASH_ALGORITHM) return record["iterations"] === PASSWORD_HASH_PASSES;
  return record["algorithm"] === "PBKDF2-HMAC-SHA256" && Number(record["iterations"]) >= LEGACY_PBKDF2_MIN && Number(record["iterations"]) <= LEGACY_PBKDF2_MAX;
}

export type Argon2idDerive = (input: {
  password: Uint8Array;
  salt: Uint8Array;
  parallelism: number;
  passes: number;
  memorySize: number;
  tagLength: number;
}) => Uint8Array;

export async function hashPassword(password: string, derive: Argon2idDerive): Promise<PasswordHash> {
  const salt = randomBytes(32);
  const digest = derive({
    password: encoder.encode(password),
    salt,
    parallelism: PASSWORD_HASH_PARALLELISM,
    passes: PASSWORD_HASH_PASSES,
    memorySize: PASSWORD_HASH_MEMORY_KIB,
    tagLength: PASSWORD_HASH_BYTES,
  });
  return {
    algorithm: PASSWORD_HASH_ALGORITHM,
    iterations: PASSWORD_HASH_PASSES,
    memoryKiB: PASSWORD_HASH_MEMORY_KIB,
    parallelism: PASSWORD_HASH_PARALLELISM,
    salt: toHex(salt),
    hash: toHex(digest),
  };
}

export async function verifyPasswordRecord(
  password: string,
  stored: PasswordHash,
  derive: Argon2idDerive,
): Promise<{ verified: boolean; upgraded?: PasswordHash }> {
  if (!/^[a-f0-9]{64}$/iu.test(stored.salt) || !/^[a-f0-9]{64}$/iu.test(stored.hash)) {
    return { verified: false };
  }
  try {
    if (stored.algorithm === PASSWORD_HASH_ALGORITHM) {
      if (stored.iterations !== PASSWORD_HASH_PASSES || stored.memoryKiB !== PASSWORD_HASH_MEMORY_KIB ||
          stored.parallelism !== PASSWORD_HASH_PARALLELISM) return { verified: false };
      const candidate = derive({
        password: encoder.encode(password),
        salt: fromHex(stored.salt),
        parallelism: PASSWORD_HASH_PARALLELISM,
        passes: PASSWORD_HASH_PASSES,
        memorySize: PASSWORD_HASH_MEMORY_KIB,
        tagLength: PASSWORD_HASH_BYTES,
      });
      return { verified: constantTimeEquals(candidate, fromHex(stored.hash)) };
    }
    if (stored.algorithm !== "PBKDF2-HMAC-SHA256" || !Number.isSafeInteger(stored.iterations) ||
        stored.iterations < LEGACY_PBKDF2_MIN || stored.iterations > LEGACY_PBKDF2_MAX) {
      return { verified: false };
    }
    const candidate = deriveLegacyPbkdf2(password, fromHex(stored.salt), stored.iterations);
    if (!constantTimeEquals(candidate, fromHex(stored.hash))) return { verified: false };
    return { verified: true, upgraded: await hashPassword(password, derive) };
  } catch {
    return { verified: false };
  }
}

function deriveLegacyPbkdf2(password: string, salt: Uint8Array, iterations: number): Uint8Array {
  // The original Phase 6 hashes were created at 600k iterations, which WebCrypto in
  // the production Workers runtime rejects. Verify those old rows with the same
  // PBKDF2-HMAC-SHA256 construction here, then immediately rehash them as Argon2id.
  const key = encoder.encode(password);
  const firstInput = new Uint8Array(salt.length + 4);
  firstInput.set(salt);
  firstInput[firstInput.length - 1] = 1;
  let u = hmacSha256(key, firstInput);
  const output = new Uint8Array(u);
  for (let index = 1; index < iterations; index += 1) {
    u = hmacSha256(key, u);
    for (let byte = 0; byte < output.length; byte += 1) output[byte] ^= u[byte]!;
  }
  return output;
}

function hmacSha256(key: Uint8Array, input: Uint8Array): Uint8Array {
  return new Uint8Array(createHmac("sha256", key).update(input).digest());
}

function constantTimeEquals(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < left.byteLength; index += 1) difference |= left[index]! ^ right[index]!;
  return difference === 0;
}
