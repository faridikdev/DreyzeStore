import { ApiError, validationError } from "./errors.js";
import type { AppSort } from "./repositories/catalogRepository.js";

export interface CursorPosition {
  key: string;
  id: string;
}

interface CursorPayload extends CursorPosition {
  v: 1;
  sort: AppSort;
  filter: string;
}

function isAppId(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value);
}

async function fingerprint(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function encodeBase64Url(value: string): string {
  const bytes = new TextEncoder().encode(value);
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join("");
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function decodeBase64Url(value: string): string {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw validationError("cursor", "is malformed.");
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function createCursor(
  sort: AppSort,
  filterKey: string,
  position: CursorPosition,
): Promise<string> {
  const payload: CursorPayload = {
    v: 1,
    sort,
    filter: await fingerprint(filterKey),
    key: position.key,
    id: position.id,
  };
  return encodeBase64Url(JSON.stringify(payload));
}

export async function parseCursor(
  value: string,
  sort: AppSort,
  filterKey: string,
): Promise<CursorPosition> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(decodeBase64Url(value));
  } catch {
    throw validationError("cursor", "is malformed.");
  }
  if (!isRecord(parsed)) throw validationError("cursor", "is malformed.");
  const keys = Object.keys(parsed).sort();
  if (keys.join(",") !== "filter,id,key,sort,v") throw validationError("cursor", "is malformed.");
  if (
    parsed["v"] !== 1 ||
    parsed["sort"] !== sort ||
    typeof parsed["filter"] !== "string" ||
    !/^[a-f0-9]{64}$/.test(parsed["filter"]) ||
    typeof parsed["key"] !== "string" ||
    typeof parsed["id"] !== "string" ||
    !isAppId(parsed["id"])
  ) {
    throw validationError("cursor", "is malformed.");
  }
  if (parsed["filter"] !== (await fingerprint(filterKey))) {
    throw new ApiError(400, "invalid_cursor", "The cursor does not match these filters.");
  }
  const key = parsed["key"] as string;
  const id = parsed["id"] as string;
  if (sort === "name" && (key.length < 1 || key.length > 160)) {
    throw validationError("cursor", "contains an invalid sort key.");
  }
  if (sort !== "name" && !isUtcTimestamp(key)) {
    throw validationError("cursor", "contains an invalid sort key.");
  }
  return { key, id };
}

function isUtcTimestamp(value: string): boolean {
  return value.length <= 40 && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value)
    && Number.isFinite(Date.parse(value));
}
