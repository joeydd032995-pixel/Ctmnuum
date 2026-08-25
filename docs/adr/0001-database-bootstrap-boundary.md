# ADR-0001: Database bootstrap boundary while v1.2 core artifact is unavailable

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-08-24
- **Related:** GitHub issue #2

## Context

Continuum v1.2 explicitly requires PostgreSQL 18, pgvector, PostgreSQL Row Level Security, transaction-scoped `SET LOCAL app.workspace_id`, distinct application/migration/maintenance roles, and an application role without `BYPASSRLS`.

The v1.2 report also references a separate machine-readable artifact containing the complete field-level DDL, dependency baseline, event schema, and Temporal definitions. That standalone artifact is not currently recoverable from the supplied files/Library.

## Decision

Foundation may establish database-platform invariants without inventing domain-table DDL.

`packages/continuum_db/sql/bootstrap.sql` therefore owns only:

1. creation of the `continuum` schema;
2. enabling the `vector` extension;
3. three distinct operational group roles;
4. a fail-closed helper for the transaction-scoped `app.workspace_id` setting;
5. initial schema grants.

No domain table is created by the bootstrap while issue #2 remains unresolved.

## Implementation choices not claimed as recovered v1.2 text

The following names/shapes are local implementation decisions made to satisfy published v1.2 invariants:

- `continuum_app`
- `continuum_migration`
- `continuum_maintenance`
- `continuum.current_workspace_id()`

These can be replaced by a later migration/ADR if the original core artifact specifies different identifiers. The semantic invariants remain unchanged.

## Security behavior

`continuum_app` is explicitly `NOBYPASSRLS`. `continuum.current_workspace_id()` returns `NULL` when `app.workspace_id` is absent or empty, allowing ordinary tenant policies of the form:

```sql
USING (workspace_id = continuum.current_workspace_id())
```

to fail closed.

Application transactions must ultimately follow:

```sql
BEGIN;
SET LOCAL app.workspace_id = '<workspace UUID>';
-- tenant-scoped statements
COMMIT;
```

## Consequences

- Database bootstrap can be implemented and tested now.
- Full Alembic/domain migrations remain blocked on issue #2 or an explicit reconstruction ADR.
- No schema field may be presented as exact v1.2 DDL unless it is directly supported by recovered source material.
