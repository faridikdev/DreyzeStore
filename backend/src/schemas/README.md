# Schema boundary

The versioned repository schema and DTO contracts live in `shared/`. The Worker validates every generated repository-v1 document with the shared validator. Query/path inputs are validated in route parsers; no separate permissive repository schema is defined in this folder.
