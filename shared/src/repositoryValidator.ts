import Ajv2020, { type ErrorObject } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import repositorySchema from "../schemas/repository-v1.schema.json" with {
  type: "json",
};
import type { RepositoryManifest } from "./contracts.js";

const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv, ["date-time", "uri"]);

const schemaValidate = ajv.compile<RepositoryManifest>(repositorySchema);

export type RepositoryValidationResult =
  | { valid: true; value: RepositoryManifest }
  | { valid: false; errors: ErrorObject[] | string[] };

function isSecureURL(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname.length > 0 && !url.username && !url.password;
  } catch {
    return false;
  }
}

export function validateRepository(value: unknown): RepositoryValidationResult {
  if (!schemaValidate(value)) {
    return { valid: false, errors: schemaValidate.errors ?? ["Invalid repository document."] };
  }

  const assetURLs = [value.icon];
  for (const app of value.apps) {
    assetURLs.push(app.icon, ...app.screenshots.map((screenshot) => screenshot.url));
    for (const version of app.versions) assetURLs.push(version.downloadURL);
  }
  if (!assetURLs.every(isSecureURL)) {
    return {
      valid: false,
      errors: ["Every repository asset and package URL must be HTTPS and must not contain credentials."],
    };
  }

  const bundleIdentifiers = new Set<string>();
  for (const app of value.apps) {
    if (bundleIdentifiers.has(app.bundleIdentifier)) {
      return {
        valid: false,
        errors: [`Duplicate bundle identifier: ${app.bundleIdentifier}`],
      };
    }
    bundleIdentifiers.add(app.bundleIdentifier);

    const releaseKeys = new Set<string>();
    for (const version of app.versions) {
      const releaseKey = `${version.version}\u0000${version.build}`;
      if (releaseKeys.has(releaseKey)) {
        return {
          valid: false,
          errors: [`Duplicate release ${version.version} build ${version.build} for ${app.bundleIdentifier}.`],
        };
      }
      releaseKeys.add(releaseKey);
    }
  }

  return { valid: true, value };
}
