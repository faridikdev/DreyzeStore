import setupWasm, { type Argon2idParams } from "argon2id/lib/setup.js";
import simdWasm from "argon2id/dist/simd.wasm";
import nonSimdWasm from "argon2id/dist/no-simd.wasm";
import { ApiError } from "../errors.js";
import { isPasswordHash, type Argon2idDerive, verifyPasswordRecord } from "./passwordKdfCore.js";

type KdfRequest = { password?: unknown; credential?: unknown };
let derivePromise: Promise<Argon2idDerive> | undefined;

export class AdminPasswordKdf {
  async fetch(request: Request): Promise<Response> {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/verify") {
      return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
    }
    try {
      const declaredLength = Number(request.headers.get("Content-Length"));
      if (Number.isFinite(declaredLength) && declaredLength > 4096) {
        throw new ApiError(413, "password_request_too_large", "The password verification request is too large.");
      }
      const body = await request.json() as KdfRequest;
      if (!body || typeof body !== "object" || Array.isArray(body) ||
          Object.keys(body).some((key) => key !== "password" && key !== "credential") ||
          typeof body.password !== "string" || new TextEncoder().encode(body.password).byteLength > 256 ||
          !isPasswordHash(body.credential)) {
        throw new ApiError(400, "invalid_password_request", "The password verification request is invalid.");
      }
      const result = await verifyPasswordRecord(body.password, body.credential, await deriveArgon2id());
      return Response.json(result, { headers: { "Cache-Control": "no-store" } });
    } catch (error) {
      const status = error instanceof ApiError ? error.status : 400;
      return Response.json(
        { error: error instanceof ApiError ? error.code : "invalid_password_request" },
        { status, headers: { "Cache-Control": "no-store" } },
      );
    }
  }
}

async function deriveArgon2id(): Promise<Argon2idDerive> {
  derivePromise ??= setupWasm(
    async (imports) => ({ module: simdWasm, instance: await WebAssembly.instantiate(simdWasm, imports) }),
    async (imports) => ({ module: nonSimdWasm, instance: await WebAssembly.instantiate(nonSimdWasm, imports) }),
  ).then((derive) => (input) => derive(input as Argon2idParams));
  return derivePromise;
}
