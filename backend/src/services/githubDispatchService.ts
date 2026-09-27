import { createPrivateKey, createSign } from "node:crypto";
import type { WorkerEnvironment } from "../env.js";
import { ApiError } from "../errors.js";

const GITHUB_API = "https://api.github.com";

export async function dispatchPackageValidator(
  environment: WorkerEnvironment,
  uploadId: string,
  dispatchTicket: string,
): Promise<void> {
  const owner = environment.GITHUB_OWNER;
  const repository = environment.GITHUB_REPOSITORY;
  const appId = environment.GITHUB_APP_ID;
  const installationId = environment.GITHUB_INSTALLATION_ID;
  const privateKey = environment.GITHUB_APP_PRIVATE_KEY;
  const workflow = environment.GITHUB_VALIDATOR_WORKFLOW ?? "validate-ipa.yml";
  const ref = environment.GITHUB_VALIDATOR_REF ?? "main";
  if (!owner || !repository || !appId || !installationId || !privateKey ||
      !/^[A-Za-z0-9_.-]{1,100}$/u.test(owner) ||
      !/^[A-Za-z0-9_.-]{1,100}$/u.test(repository) ||
      !/^[A-Za-z0-9_.-]{1,100}$/u.test(workflow) ||
      !/^[A-Za-z0-9_./-]{1,128}$/u.test(ref)) {
    throw new ApiError(503, "validator_unavailable", "The isolated package validator is not configured.");
  }

  try {
    const fetcher = environment.TEST_FETCH ?? fetch;
    const jwt = createAppJwt(appId, privateKey);
    const accessResponse = await fetcher(GITHUB_API + "/app/installations/" + encodeURIComponent(installationId) + "/access_tokens", {
      method: "POST",
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: "Bearer " + jwt,
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        repositories: [repository],
        permissions: { actions: "write" },
      }),
    });
    if (!accessResponse.ok) throw new Error("GitHub App token request failed.");
    const accessBody = await accessResponse.json() as { token?: unknown };
    if (typeof accessBody.token !== "string" || accessBody.token.length < 20) {
      throw new Error("GitHub App token response was invalid.");
    }

    const dispatchResponse = await fetcher(
      GITHUB_API + "/repos/" + encodeURIComponent(owner) + "/" + encodeURIComponent(repository) +
        "/actions/workflows/" + encodeURIComponent(workflow) + "/dispatches",
      {
        method: "POST",
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: "Bearer " + accessBody.token,
          "X-GitHub-Api-Version": "2022-11-28",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ref, inputs: { upload_id: uploadId, dispatch_ticket: dispatchTicket } }),
      },
    );
    if (dispatchResponse.status !== 204) throw new Error("GitHub workflow dispatch failed.");
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(503, "validator_dispatch_failed", "The package validator could not be queued.");
  }
}

function createAppJwt(appId: string, pem: string): string {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64Url(JSON.stringify({ iss: appId, iat: nowSeconds - 60, exp: nowSeconds + 540 }));
  const signingInput = header + "." + payload;
  const signer = createSign("RSA-SHA256");
  signer.update(signingInput);
  signer.end();
  const signature = base64UrlBytes(signer.sign(createPrivateKey(pem)));
  return signingInput + "." + signature;
}

function base64Url(value: string): string {
  return base64UrlBytes(new TextEncoder().encode(value));
}

function base64UrlBytes(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}
