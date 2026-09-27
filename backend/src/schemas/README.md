# Schema boundary

The versioned repository schema and DTO contracts live in `shared/`. Backend handlers must validate repository and request payloads against those shared contracts before use; no independent permissive schema is defined here.
