import type { ApiContext } from "../errors.js";

export interface CacheOptions {
  maxAgeSeconds: number;
  sharedMaxAgeSeconds?: number;
  staleWhileRevalidateSeconds?: number;
}

function cacheControl(options: CacheOptions): string {
  const values = [
    "public",
    `max-age=${options.maxAgeSeconds}`,
    `s-maxage=${options.sharedMaxAgeSeconds ?? options.maxAgeSeconds}`,
  ];
  if (options.staleWhileRevalidateSeconds !== undefined) {
    values.push(`stale-while-revalidate=${options.staleWhileRevalidateSeconds}`);
  }
  return values.join(", ");
}

async function strongETag(body: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `"${hex}"`;
}

function matchesIfNoneMatch(header: string | undefined, etag: string): boolean {
  if (!header) return false;
  const comparable = etag.replace(/^W\//, "");
  return header.split(",").some((candidate) => {
    const token = candidate.trim();
    return token === "*" || token.replace(/^W\//, "") === comparable;
  });
}

export async function cachedJsonResponse(
  context: ApiContext,
  value: unknown,
  options: CacheOptions,
): Promise<Response> {
  const body = JSON.stringify(value);
  const etag = await strongETag(body);
  const headers = new Headers({
    "Cache-Control": cacheControl(options),
    ETag: etag,
    "Content-Type": "application/json; charset=utf-8",
  });

  if (matchesIfNoneMatch(context.req.header("If-None-Match"), etag)) {
    headers.delete("Content-Type");
    return new Response(null, { status: 304, headers });
  }
  return new Response(body, { status: 200, headers });
}

export function noStoreJsonResponse(context: ApiContext, value: unknown): Response {
  const response = context.json(value);
  response.headers.set("Cache-Control", "no-store");
  return response;
}
