import type { ApiEnvelope, ApiHealth } from "@dreyzestore/shared";

export class AdminApiError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AdminApiError";
  }
}

function isHealthResponse(value: unknown): value is ApiEnvelope<ApiHealth> {
  if (typeof value !== "object" || value === null || !("data" in value)) return false;
  const data = value.data;
  return (
    typeof data === "object" &&
    data !== null &&
    "status" in data &&
    data.status === "ok" &&
    "database" in data &&
    data.database === "ready"
  );
}

export async function checkApiHealth(
  baseURL: string | undefined,
  fetchImplementation: typeof fetch = fetch,
): Promise<ApiHealth> {
  if (!baseURL) {
    throw new AdminApiError("Set VITE_API_BASE_URL to the API base URL to check the connection.");
  }

  let endpoint: URL;
  try {
    endpoint = new URL(`${baseURL.replace(/\/+$/, "")}/health`);
  } catch {
    throw new AdminApiError("VITE_API_BASE_URL is not a valid URL.");
  }

  const isLocalHTTP = endpoint.protocol === "http:" && ["localhost", "127.0.0.1", "::1", "[::1]"].includes(endpoint.hostname);
  if (endpoint.protocol !== "https:" && !isLocalHTTP) {
    throw new AdminApiError("The API URL must use HTTPS outside local development.");
  }

  let response: Response;
  try {
    response = await fetchImplementation(endpoint, {
      headers: { Accept: "application/json" },
    });
  } catch {
    throw new AdminApiError("The API could not be reached.");
  }

  if (!response.ok) throw new AdminApiError(`The API returned status ${response.status}.`);

  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new AdminApiError("The API returned an invalid health response.");
  }

  if (!isHealthResponse(body)) throw new AdminApiError("The API returned an invalid health response.");
  return body.data;
}
