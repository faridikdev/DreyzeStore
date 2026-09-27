import type { Context } from "hono";
import { ApiError } from "../errors.js";
import type { AdminEnvironment } from "./adminSecurity.js";

export async function readBoundedJson<T>(
  context: Context<AdminEnvironment>,
  maximumBytes = 16_384,
): Promise<T> {
  const contentType = context.req.header("Content-Type")?.split(";")[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new ApiError(415, "unsupported_media_type", "Send a JSON request body.");
  }
  const declaredLength = Number(context.req.header("Content-Length") ?? 0);
  if (declaredLength > maximumBytes) {
    throw new ApiError(413, "request_too_large", "The request body is too large.");
  }
  const body = context.req.raw.body;
  if (!body) throw new ApiError(400, "invalid_request", "A JSON request body is required.");
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maximumBytes) {
        await reader.cancel();
        throw new ApiError(413, "request_too_large", "The request body is too large.");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  try {
    const bytes = new Uint8Array(totalBytes);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as T;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_json", "The request body must contain valid UTF-8 JSON.");
  }
}
