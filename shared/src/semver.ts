interface ParsedSemanticVersion {
  major: bigint;
  minor: bigint;
  patch: bigint;
  prerelease: string[] | null;
}

const SEMVER_PATTERN =
  /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

function parseSemanticVersion(value: string): ParsedSemanticVersion {
  const match = SEMVER_PATTERN.exec(value);
  if (!match) throw new TypeError("Invalid semantic version.");

  return {
    major: BigInt(match[1]!),
    minor: BigInt(match[2]!),
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
