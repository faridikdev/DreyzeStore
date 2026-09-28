interface ParsedSemanticVersion {
  major: bigint;
  minor: bigint;
  patch: bigint;
  prerelease: string[] | null;
}

const SEMVER_PATTERN =
  /^(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?(?:\.(0|[1-9][0-9]*))?(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

function parseSemanticVersion(value: string): ParsedSemanticVersion {
  const match = SEMVER_PATTERN.exec(value);
  if (!match) throw new TypeError("Invalid semantic version.");

  return {
    major: BigInt(match[1]!),
    minor: BigInt(match[2] ?? "0"),
    patch: BigInt(match[3] ?? "0"),
    prerelease: match[4]?.split(".") ?? null,
  };
}

function comparePrereleaseIdentifiers(left: string, right: string): number {
  const leftNumeric = /^[0-9]+$/.test(left);
  const rightNumeric = /^[0-9]+$/.test(right);

  if (leftNumeric && rightNumeric) {
    const leftNumber = BigInt(left);
    const rightNumber = BigInt(right);
    return leftNumber < rightNumber ? -1 : leftNumber > rightNumber ? 1 : 0;
  }
  if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
  return left < right ? -1 : left > right ? 1 : 0;
}

/**
 * Compare versions according to SemVer precedence. Two-component versions are
 * normalized with a zero patch; build metadata does not affect precedence.
 */
export function compareSemanticVersions(left: string, right: string): number {
  const a = parseSemanticVersion(left);
  const b = parseSemanticVersion(right);

  for (const [leftPart, rightPart] of [
    [a.major, b.major],
    [a.minor, b.minor],
    [a.patch, b.patch],
  ] as const) {
    if (leftPart < rightPart) return -1;
    if (leftPart > rightPart) return 1;
  }

  if (a.prerelease === null || b.prerelease === null) {
    if (a.prerelease === b.prerelease) return 0;
    return a.prerelease === null ? 1 : -1;
  }

  const sharedLength = Math.min(a.prerelease.length, b.prerelease.length);
  for (let index = 0; index < sharedLength; index += 1) {
    const result = comparePrereleaseIdentifiers(a.prerelease[index]!, b.prerelease[index]!);
    if (result !== 0) return result;
  }
  return a.prerelease.length < b.prerelease.length ? -1 : a.prerelease.length > b.prerelease.length ? 1 : 0;
}

export function isSemanticVersion(value: string): boolean {
  return SEMVER_PATTERN.test(value);
}

interface BuildPart {
  kind: "numeric" | "text";
  value: string;
}

function buildParts(value: string): BuildPart[] {
  return (value.match(/[0-9]+|[^0-9]+/g) ?? []).map((part) => ({
    kind: /^[0-9]+$/.test(part) ? "numeric" : "text",
    value: part,
  }));
}

/**
 * Compare Apple build identifiers using deterministic natural ordering.
 * Numeric runs are compared as integers (so 10 > 2); text runs use a
 * case-insensitive ordinal comparison. Separators are retained as text.
 */
export function compareBuildNumbers(left: string, right: string): number {
  if (!left || !right) throw new TypeError("Build identifiers must not be empty.");
  const a = buildParts(left);
  const b = buildParts(right);
  const sharedLength = Math.min(a.length, b.length);
  for (let index = 0; index < sharedLength; index += 1) {
    const leftPart = a[index]!;
    const rightPart = b[index]!;
    if (leftPart.kind !== rightPart.kind) return leftPart.kind === "numeric" ? 1 : -1;
    if (leftPart.kind === "numeric") {
      const leftNumber = BigInt(leftPart.value);
      const rightNumber = BigInt(rightPart.value);
      if (leftNumber < rightNumber) return -1;
      if (leftNumber > rightNumber) return 1;
    } else {
      const leftText = leftPart.value.toLowerCase();
      const rightText = rightPart.value.toLowerCase();
      if (leftText < rightText) return -1;
      if (leftText > rightText) return 1;
    }
  }
  return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
}

export function compareReleaseVersions(
  leftVersion: string,
  leftBuild: string,
  rightVersion: string,
  rightBuild: string,
): number {
  const versionOrder = compareSemanticVersions(leftVersion, rightVersion);
  return versionOrder === 0 ? compareBuildNumbers(leftBuild, rightBuild) : versionOrder;
}
