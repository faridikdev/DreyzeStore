import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";
import { isPasswordHash, type PasswordHash } from "./passwordKdfCore.js";

const MAX_VERIFY_RESPONSE_BYTES = 4_096;

export async function verifyPassword(
  environment: WorkerEnvironment,
  password: string,
  credential: PasswordHash,
  shard: string,
): Promise<{ verified: boolean; upgraded?: PasswordHash }> {
  if (!/^[a-f0-9]$/iu.test(shard) || password.length > 256 || !isPasswordHash(credential)) {
    throw new ApiError(503, "password_verification_unavailable", "Password verification is temporarily unavailable.");
  }
  try {
    const objectId = environment.PASSWORD_KDF.idFromName("admin-password-kdf:" + shard.toLowerCase());
    const response = await environment.PASSWORD_KDF.get(objectId).fetch("https://password-kdf.internal/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password, credential }),
    });
    if (!response.ok) throw new Error("Password KDF rejected the internal request.");
    const declaredLength = Number(response.headers.get("Content-Length"));
    if (Number.isFinite(declaredLength) && declaredLength > MAX_VERIFY_RESPONSE_BYTES) throw new Error("Password KDF response exceeded its limit.");
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > MAX_VERIFY_RESPONSE_BYTES) throw new Error("Password KDF response exceeded its limit.");
    const result = JSON.parse(text) as { verified?: unknown; upgraded?: unknown };
    if (typeof result.verified !== "boolean" || (result.upgraded !== undefined && !isPasswordHash(result.upgraded))) {
      throw new Error("Password KDF returned an invalid response.");
    }
    return {
      verified: result.verified,
      ...(result.upgraded && isPasswordHash(result.upgraded) ? { upgraded: result.upgraded } : {}),
    };
  } catch {
    throw new ApiError(503, "password_verification_unavailable", "Password verification is temporarily unavailable.");
  }
}
