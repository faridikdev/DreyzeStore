import { describe, expect, it } from "vitest";
import type { RepositoryManifest } from "../src/contracts.js";
import { validateRepository } from "../src/repositoryValidator.js";

const validRepository: RepositoryManifest = {
  schemaVersion: 1,
  name: "Community Tools",
  identifier: "org.example.community",
  description: "A test repository with authorized example metadata.",
  icon: "https://cdn.example.org/repository.png",
  generatedAt: "2026-09-27T00:00:00Z",
  apps: [
    {
      bundleIdentifier: "org.example.reader",
      name: "Example Reader",
      developer: "Example Studio",
      category: "Productivity",
      description: "A fixture used only by schema tests.",
      icon: "https://cdn.example.org/reader.png",
      screenshots: [
        {
          url: "https://cdn.example.org/reader-screen.png",
          width: 1290,
          height: 2796,
          alt: "An example reader screen",
        },
      ],
      versions: [
        {
          version: "1.2.0-beta.1",
          build: "42",
          versionDate: "2026-09-26T18:30:00Z",
          minimumOSVersion: "16.0",
          downloadURL: "https://cdn.example.org/reader.ipa",
          sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          size: 12345678,
          releaseNotes: "Example release notes.",
          channel: "beta",
        },
      ],
    },
  ],
};

describe("repository v1 validation", () => {
  it("accepts a valid HTTPS manifest and package record", () => {
    expect(validateRepository(validRepository).valid).toBe(true);
  });

  it("rejects malformed bundle identifiers", () => {
    const candidate = structuredClone(validRepository);
    candidate.apps[0]!.bundleIdentifier = "org..reader";
    expect(validateRepository(candidate).valid).toBe(false);
  });

  it("rejects unsupported versions and malformed build identifiers", () => {
    const candidate = structuredClone(validRepository);
    candidate.apps[0]!.versions[0]!.version = "latest";
    expect(validateRepository(candidate).valid).toBe(false);

    candidate.apps[0]!.versions[0]!.version = "1.2.0";
    candidate.apps[0]!.versions[0]!.build = "build number with spaces";
    expect(validateRepository(candidate).valid).toBe(false);

    candidate.apps[0]!.versions[0]!.build = "42";
    candidate.apps[0]!.versions[0]!.version = "1.2.0-beta.01";
    expect(validateRepository(candidate).valid).toBe(false);
  });

  it("rejects non-HTTPS package, icon, and screenshot URLs", () => {
    const candidate = structuredClone(validRepository);
    candidate.apps[0]!.versions[0]!.downloadURL = "http://cdn.example.org/reader.ipa";
    expect(validateRepository(candidate).valid).toBe(false);
  });

  it("rejects URL credentials and non-UTC timestamps", () => {
    const credentialURL = structuredClone(validRepository);
    credentialURL.apps[0]!.versions[0]!.downloadURL = "https://publisher:secret@cdn.example.org/reader.ipa";
    expect(validateRepository(credentialURL).valid).toBe(false);

    const nonUTCDate = structuredClone(validRepository);
    nonUTCDate.apps[0]!.versions[0]!.versionDate = "2026-09-26T20:30:00+02:00";
    expect(validateRepository(nonUTCDate).valid).toBe(false);
  });

  it("rejects bad checksums, sizes, minimum OS versions, and screenshot metadata", () => {
    const candidate = structuredClone(validRepository);
    candidate.apps[0]!.versions[0]!.sha256 = "abc123";
    expect(validateRepository(candidate).valid).toBe(false);

    candidate.apps[0]!.versions[0]!.sha256 = validRepository.apps[0]!.versions[0]!.sha256;
    candidate.apps[0]!.versions[0]!.size = 0;
    expect(validateRepository(candidate).valid).toBe(false);

    candidate.apps[0]!.versions[0]!.size = 12345678;
    candidate.apps[0]!.versions[0]!.minimumOSVersion = "sixteen";
    expect(validateRepository(candidate).valid).toBe(false);

    candidate.apps[0]!.versions[0]!.minimumOSVersion = "16.0";
    candidate.apps[0]!.screenshots[0]!.width = 0;
    expect(validateRepository(candidate).valid).toBe(false);
  });

  it("rejects unknown fields and duplicate app bundle identifiers", () => {
    const withUnknown = { ...validRepository, productionSecret: "never accepted" };
    expect(validateRepository(withUnknown).valid).toBe(false);

    const duplicate = structuredClone(validRepository);
    duplicate.apps.push({ ...duplicate.apps[0]! });
    const result = validateRepository(duplicate);
    expect(result.valid).toBe(false);
    if (!result.valid) {
      expect(result.errors.join(" ")).toContain("Duplicate bundle identifier");
    }
  });

  it("rejects duplicate version/build pairs for an app", () => {
    const duplicate = structuredClone(validRepository);
    duplicate.apps[0]!.versions.push({ ...duplicate.apps[0]!.versions[0]! });
    const result = validateRepository(duplicate);
    expect(result.valid).toBe(false);
    if (!result.valid) {
      expect(result.errors.join(" ")).toContain("Duplicate release");
    }
  });
});
