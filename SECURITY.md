# Security policy

Do not report security issues in a public issue. Use GitHub's private vulnerability reporting for the repository once it is enabled, or contact the maintainers through the private channel listed on the repository's security page.

Do not include credentials, private keys, user tokens, or copyrighted package contents in reports. Include the affected component, impact, reproduction steps, and a suggested mitigation where possible.

## Security boundaries

- Repository metadata and packages are untrusted input. A matching SHA-256 confirms byte integrity against the published digest; it does not certify publisher identity or application safety.
- The iOS client must never report installation success without confirmation from an installation backend.
- No secrets, signing keys, IPA files, or production configuration belong in Git.
- Package/archive validation must enforce size, path, and expansion limits before any extraction or handoff.
- The API must not expose stack traces, authentication material, signed upload URLs, or internal storage keys.

See [docs/security.md](docs/security.md) for the architecture threat boundaries and planned controls.
