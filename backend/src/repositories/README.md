# Repository layer boundary

The health query is isolated in `db/healthRepository.ts`. Catalog D1 statements live in `catalogRepository.ts`; route handlers must not issue ad hoc SQL or return database rows directly. Repository methods return internal row types, which services validate and map into public DTOs.
