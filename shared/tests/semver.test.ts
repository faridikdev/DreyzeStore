import { describe, expect, it } from "vitest";
import { compareBuildNumbers, compareReleaseVersions, compareSemanticVersions, isSemanticVersion } from "../src/semver.js";

describe("semantic version precedence", () => {
  it("compares numeric components instead of version strings", () => {
    expect(compareSemanticVersions("1", "1.0")).toBe(0);
    expect(compareSemanticVersions("1.0", "1.1")).toBeLessThan(0);
    expect(compareSemanticVersions("1.9", "1.10")).toBeLessThan(0);
    expect(compareSemanticVersions("2.0.0", "10.0.0")).toBeLessThan(0);
  });

  it("sorts prereleases before the matching stable release", () => {
    expect(compareSemanticVersions("2.0-beta", "2.0")).toBeLessThan(0);
    expect(compareSemanticVersions("2.0.0-beta.2", "2.0.0-beta.10")).toBeLessThan(0);
    expect(compareSemanticVersions("2.0.0-alpha", "2.0.0-beta")).toBeLessThan(0);
  });

  it("ignores build metadata when comparing precedence", () => {
    expect(compareSemanticVersions("1.2.3+one", "1.2.3+two")).toBe(0);
  });

  it("rejects malformed versions", () => {
    expect(isSemanticVersion("1")).toBe(true);
    expect(isSemanticVersion("2026.9")).toBe(true);
    expect(isSemanticVersion("1.2.3-beta.1")).toBe(true);
    expect(isSemanticVersion("1.2.3-beta.01")).toBe(false);
    expect(() => compareSemanticVersions("latest", "1.0")).toThrow(TypeError);
  });

  it("compares build identifiers naturally and uses builds only for equal versions", () => {
    expect(compareBuildNumbers("2", "10")).toBeLessThan(0);
    expect(compareBuildNumbers("2026.9", "2026.10")).toBeLessThan(0);
    expect(compareBuildNumbers("2.0-beta", "2.0-rc")).toBeLessThan(0);
    expect(compareReleaseVersions("1.0", "9", "1.0.0", "10")).toBeLessThan(0);
    expect(compareReleaseVersions("1.0", "10", "1.1", "1")).toBeLessThan(0);
  });
});
