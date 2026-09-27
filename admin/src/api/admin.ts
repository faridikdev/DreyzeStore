export interface AdminSession {
  id: string;
  email: string;
  role: "admin" | "editor";
  csrfToken: string;
  expiresAt: string;
}

export interface AdminError {
  code: string;
  message: string;
  requestId: string;
}

let csrfToken = "";
const baseURL = import.meta.env.VITE_API_BASE_URL?.replace(/\/$/u, "") ?? "";

export function setCsrfToken(value: string): void {
  csrfToken = value;
}

export function apiURL(path: string): string {
  if (!baseURL) throw new Error("Set VITE_API_BASE_URL to the DreyzeStore API URL.");
  return baseURL + path;
}

export async function apiRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  const method = (options.method ?? "GET").toUpperCase();
  const headers = new Headers(options.headers);
  if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  if (!["GET", "HEAD", "OPTIONS"].includes(method)) {
    if (!csrfToken) throw new Error("Your admin session needs to be refreshed.");
    headers.set("X-CSRF-Token", csrfToken);
  }
  const response = await fetch(apiURL(path), {
    ...options,
    method,
    headers,
    credentials: "include",
    cache: "no-store",
  });
  const payload = await response.json().catch(() => null) as {
    data?: T;
    error?: AdminError;
  } | null;
  if (!response.ok || !payload || !("data" in payload)) {
    throw new AdminRequestError(
      payload?.error?.message ?? "The request could not be completed.",
      payload?.error?.code ?? "request_failed",
      payload?.error?.requestId ?? response.headers.get("X-Request-Id") ?? "",
      response.status,
    );
  }
  return payload.data as T;
}

export class AdminRequestError extends Error {
  constructor(message: string, readonly code: string, readonly requestId: string, readonly status: number) {
    super(message);
    this.name = "AdminRequestError";
  }
}

export function currentCsrfToken(): string {
  return csrfToken;
}
