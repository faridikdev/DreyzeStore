import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";

interface OidcHeader {
  alg?: unknown;
  kid?: unknown;
  typ?: unknown;
}

interface OidcClaims {
  iss?: unknown;
  aud?: unknown;
  exp?: unknown;
  iat?: unknown;
  nbf?: unknown;
  repository?: unknown;
  ref?: unknown;
  event_name?: unknown;
  workflow_ref?: unknown;
  run_id?: unknown;
  run_attempt?: unknown;
}

interface GitHubJsonWebKey extends JsonWebKey {
  kid?: string;
}

interface JwkSet {
  keys?: GitHubJsonWebKey[];
}

export interface VerifiedWorkflowIdentity {
  runId: string;
  runAttempt: number;
}

let jwkCache: { url: string; expiresAt: number; keys: GitHubJsonWebKey[] } | undefined;

export async function verifyValidatorOidc(
  environment: WorkerEnvironment,
  token: string,
): Promise<VerifiedWorkflowIdentity> {
  const parts = token.split(".");
  if (parts.length !== 3 || token.length > 12_000) throw unauthorized();
  let header: OidcHeader;
  let claims: OidcClaims;
  try {
    header = JSON.parse(decodePart(parts[0]!)) as OidcHeader;
    claims = JSON.parse(decodePart(parts[1]!)) as OidcClaims;
  } catch {
    throw unauthorized();
  }
  if (header.alg !== "RS256" || typeof header.kid !== "string" || header.kid.length > 256) throw unauthorized();
  const jwksURL = environment.VALIDATOR_OIDC_JWKS_URL ?? "https://token.actions.githubusercontent.com/.well-known/jwks";
  let keySet: GitHubJsonWebKey[];
  try {
    keySet = await loadJwks(environment, jwksURL);
  } catch {
    throw new ApiError(503, "validator_identity_unavailable", "The validator identity could not be checked.");
  }
  const jwk = keySet.find((key) => key.kid === header.kid && key.kty === "RSA");
  if (!jwk) throw unauthorized();
  let validSignature: boolean;
  try {
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    validSignature = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      base64UrlBytes(parts[2]!).slice().buffer as ArrayBuffer,
      new TextEncoder().encode(parts[0] + "." + parts[1]).buffer as ArrayBuffer,
    );
  } catch {
    throw unauthorized();
  }
  if (!validSignature) throw unauthorized();

  const nowSeconds = Math.floor(Date.now() / 1000);
  const owner = environment.GITHUB_OWNER ?? "faridikdev";
  const repository = environment.GITHUB_REPOSITORY ?? "DreyzeStore";
  const workflow = environment.GITHUB_VALIDATOR_WORKFLOW ?? "validate-ipa.yml";
  const branch = environment.GITHUB_VALIDATOR_REF ?? "main";
  const audience = environment.VALIDATOR_OIDC_AUDIENCE ?? "";
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  const expectedWorkflow = owner + "/" + repository + "/.github/workflows/" + workflow + "@refs/heads/" + branch;
  if (
    claims.iss !== "https://token.actions.githubusercontent.com" ||
    !audience ||
    !audiences.includes(audience) ||
    typeof claims.exp !== "number" ||
    claims.exp < nowSeconds - 30 ||
    typeof claims.iat !== "number" ||
    claims.iat > nowSeconds + 30 ||
    (typeof claims.nbf === "number" && claims.nbf > nowSeconds + 30) ||
    claims.repository !== owner + "/" + repository ||
    claims.ref !== "refs/heads/" + branch ||
    claims.event_name !== "workflow_dispatch" ||
    claims.workflow_ref !== expectedWorkflow ||
    typeof claims.run_id !== "string" ||
    !/^\d{1,20}$/u.test(claims.run_id) ||
    (typeof claims.run_attempt !== "number" && typeof claims.run_attempt !== "string") ||
    !/^\d{1,6}$/u.test(String(claims.run_attempt)) ||
    Number(claims.run_attempt) < 1
  ) {
    throw unauthorized();
  }
  return { runId: claims.run_id, runAttempt: Number(claims.run_attempt) };
}

async function loadJwks(environment: WorkerEnvironment, url: string): Promise<GitHubJsonWebKey[]> {
  const parsedURL = new URL(url);
  if (parsedURL.protocol !== "https:" || parsedURL.hostname !== "token.actions.githubusercontent.com" ||
      parsedURL.pathname !== "/.well-known/jwks") {
    throw new Error("Untrusted JWKS endpoint.");
  }
  if (jwkCache && jwkCache.url === url && jwkCache.expiresAt > Date.now()) return jwkCache.keys;
  const fetcher = environment.TEST_FETCH ?? fetch;
  const response = await fetcher(url, { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error("JWKS request failed.");
  const body = await response.json() as JwkSet;
  if (!Array.isArray(body.keys) || body.keys.length < 1 || body.keys.length > 20) throw new Error("Invalid JWKS.");
  jwkCache = { url, keys: body.keys, expiresAt: Date.now() + 5 * 60 * 1000 };
  return body.keys;
}

function decodePart(part: string): string {
  return new TextDecoder("utf-8", { fatal: true }).decode(base64UrlBytes(part));
}

function base64UrlBytes(part: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/u.test(part)) throw new Error("Invalid JWT base64url.");
  const normalized = part.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  const result = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) result[index] = binary.charCodeAt(index);
  return result;
}

function unauthorized(): ApiError {
  return new ApiError(401, "validator_unauthenticated", "The validator identity was not accepted.");
}
