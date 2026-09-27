# Security boundary

Public catalog routes use explicit response projections, prepared D1 statements, bounded inputs, generic errors, request IDs, and exact-origin CORS. Admin sessions, CSRF validation, admin rate limiting, upload tickets, and package provenance checks are not implemented yet. Do not expose state-changing admin routes until those controls are present. Shared security requirements are in `docs/security.md`.
