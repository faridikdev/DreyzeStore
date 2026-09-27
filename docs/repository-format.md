# Repository format v1

**Status:** Phase 1 contract baseline; the normative schema is checked in at `shared/schemas/repository-v1.schema.json`.

## Purpose and versioning

A repository is a versioned JSON document served from an HTTPS URL. The official DreyzeStore catalog uses the same public shape as third-party sources. `schemaVersion` is an integer. A client that does not support a schema version rejects it with a readable error; it does not guess or silently discard fields. The schema uses JSON Schema Draft 2020-12 and is bundled with the app, never downloaded as an executable validation rule.

V1 rejects unknown properties. Additive or breaking changes require an explicit compatible schema-version policy; a breaking field change increments `schemaVersion`.

## Document shape

```json
{
  "schemaVersion": 1,
  "name": "Dreyze Repository",
  "identifier": "com.dreyze.official",
  "description": "The official DreyzeStore repository.",
  "icon": "https://cdn.example.org/repos/dreyze.png",
  "generatedAt": "2026-09-27T00:00:00Z",
  "apps": [
    {
      "bundleIdentifier": "org.example.reader",
      "name": "Example Reader",
      "developer": "Example Studio",
      "category": "Productivity",
      "description": "A sample description from the publisher.",
      "icon": "https://cdn.example.org/apps/reader/icon.png",
      "screenshots": [
        {
          "url": "https://cdn.example.org/apps/reader/screen-1.png",
          "width": 1290,
          "height": 2796,
          "alt": "Reading view with a book open"
        }
      ],
      "versions": [
        {
          "version": "1.2.0",
          "build": "42",
          "versionDate": "2026-09-27T00:00:00Z",
          "minimumOSVersion": "16.0",
          "downloadURL": "https://cdn.example.org/packages/reader/1.2.0/app.ipa",
          "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "size": 12345678,
          "releaseNotes": "Bug fixes and performance improvements.",
          "channel": "stable"
        }
      ]
    }
  ]
}
```

The example is schema documentation only. It is not production catalog data and will not be bundled as a live app listing.

## Normative field rules

### Repository

- `schemaVersion`: required integer; v1 is `1`.
- `name`: required, non-empty, bounded plain text.
- `identifier`: required reverse-DNS style stable repository ID. It is not an authentication credential.
- `description`: required, bounded plain text.
- `icon`: required absolute HTTPS URL.
- `generatedAt`: required UTC RFC 3339 timestamp.
- `apps`: required bounded array; empty is allowed for a newly created source.

### App

- `bundleIdentifier`: required reverse-DNS bundle ID; unique within one repository document.
- `name`, `developer`, `description`, `icon`, `category`: required. Text is displayed as untrusted text, never HTML.
- `category`: one of `Utilities`, `Developer Tools`, `Games`, `Emulators`, `Media`, `Productivity`, `Social`, `Customization`, or `Other`.
- `screenshots`: required bounded array (zero or more). Each element has an HTTPS URL, positive pixel dimensions, and bounded accessibility `alt` text.
- `versions`: required non-empty bounded array. Release order is not trusted; clients perform semantic version selection.

### Version

- `version`: required app version string. Compare semantically, including prerelease identifiers; never with string `<`.
- `build`: required publisher build string, preserved exactly.
- `versionDate`: required UTC RFC 3339 timestamp.
- `minimumOSVersion`: required dotted numeric OS version.
- `downloadURL`: required absolute HTTPS URL with no embedded username/password. HTTPS redirects must remain HTTPS.
- `sha256`: required lowercase 64-character hexadecimal digest of the exact downloaded IPA bytes.
- `size`: required positive integer in bytes. The runtime applies a separately configured maximum package size and compares actual downloaded bytes to this value.
- `releaseNotes`: required bounded plain text.
- `channel`: required `stable` or `beta`.

Use `additionalProperties: false` at every object level; reasonable `maxLength`, `maxItems`, and `maxProperties` bounds; `format: uri` plus application-level HTTPS enforcement; a digest pattern; and date-time validation. JSON Schema shape checks do not replace semantic checks for duplicate apps, release ordering, supported categories, maximum bytes, redirects, or repository trust.

## Client validation and trust behavior

1. Require HTTPS for the source URL and every linked asset/package. Reject URL user-info and unsupported schemes. Restrict redirects to HTTPS and a bounded redirect count.
2. Bound response bytes and parsing time before decoding JSON. Reject unknown schema versions and unknown fields.
3. Validate the manifest with the bundled v1 schema, then perform semantic checks.
4. Present an explicit trust notice before adding an unknown source. Store the source URL and stable repository identifier; do not interpret a matching SHA-256 as a safety review.
5. Download the exact release bytes to temporary storage, compare byte count and SHA-256, and inspect package metadata before offering an installation handoff.
6. Keep recent source fetch errors separate from cached content. A failed refresh leaves the last validated manifest available with an offline indicator.

The digest protects against accidental or in-transit byte changes relative to the manifest. It does not prove that the publisher is known, that the package is safe, or that the metadata host itself has not been compromised. The security implications and later signed-metadata option are described in [security.md](security.md).

## Version ordering

Interpret numeric core components numerically and compare prerelease identifiers according to SemVer ordering. Missing patch components are zero for legacy `major.minor` releases. A stable release sorts after its matching prerelease (`2.0-beta < 2.0`). Use build and date only as tie-breakers for display when semantically equivalent releases exist; do not silently treat a build string as a version.

## Schema ownership

`shared/schemas/repository-v1.schema.json` is the normative machine schema. The iOS decoder, backend publisher, admin form, and schema verification workflow must agree with it. Hand-maintained duplicate definitions are not authoritative. Any future version keeps a safe example fixture and migration/rejection tests beside the schema.

The format is intentionally independent of a server database. A source can host this document as static JSON on any HTTPS host; adding a repository does not grant it access to the official API or admin system.
