# Repository layer boundary

The health query is isolated in `db/healthRepository.ts`. Product data repositories are added with the catalog API phase; route handlers must not issue ad hoc SQL or return database rows directly.
