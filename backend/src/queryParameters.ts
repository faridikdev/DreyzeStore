import { ApiError, validationError } from "./errors.js";

export const MAX_PAGE_SIZE = 100;
export const DEFAULT_PAGE_SIZE = 24;
export const MAX_PAGE_NUMBER = 1000;

export function readQuery(url: string, allowedKeys: readonly string[]): Map<string, string> {
  const parameters = new URL(url).searchParams;
  const allowed = new Set(allowedKeys);
  const values = new Map<string, string>();

  for (const key of new Set(parameters.keys())) {
    if (!allowed.has(key)) throw validationError(key, "is not a supported query parameter.");
    const matches = parameters.getAll(key);
    if (matches.length !== 1) throw validationError(key, "must be provided at most once.");
    values.set(key, matches[0]!);
  }
  return values;
}

function parsePositiveInteger(
  value: string | undefined,
  field: string,
  defaultValue: number,
  maximum: number,
): number {
  if (value === undefined) return defaultValue;
  if (!/^[1-9][0-9]{0,5}$/.test(value)) {
    throw validationError(field, "must be a positive whole number.");
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed > maximum) {
    throw validationError(field, `must not exceed ${maximum}.`);
  }
  return parsed;
}

export interface PaginationInput {
  page: number;
  pageSize: number;
  cursor?: string;
}

export function parsePagination(query: Map<string, string>): PaginationInput {
  const page = parsePositiveInteger(query.get("page"), "page", 1, MAX_PAGE_NUMBER);
  const pageSize = parsePositiveInteger(query.get("limit"), "limit", DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE);
  const cursor = query.get("cursor");
  if (cursor !== undefined) {
    if (query.has("page")) throw validationError("cursor", "cannot be combined with page.");
    if (cursor.length > 1024) throw new ApiError(414, "uri_too_long", "The cursor is too long.");
    if (cursor.length === 0) throw validationError("cursor", "must not be empty.");
    return { page: 1, pageSize, cursor };
  }
  return { page, pageSize };
}
