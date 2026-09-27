# Security boundary

Admin sessions, CSRF validation, rate limiting, upload tickets, and package provenance checks are not implemented in the foundation. Do not expose state-changing admin routes until those controls are present. Shared security requirements are in `docs/security.md`.
