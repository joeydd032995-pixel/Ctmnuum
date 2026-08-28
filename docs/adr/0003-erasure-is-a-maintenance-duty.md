# ADR-0003: Hard deletion belongs to the maintenance role, not the application

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-08-27
- **Related:** `FND-SPEC-001`; ADR-0001 (role split); PR #8
- **Supersedes:** the `[DECISION]` comment introduced with the table grants in PR #8

## Context

PR #8 granted `continuum_app` the table privileges its RLS policies need —
before that it could not reach 24 of the 25 tables, so every tenant policy was
unreachable. That change deliberately withheld `DELETE` from every role, marked
`[DECISION]`, pending this ADR.

The consequence was sharper than "the application cannot delete": **no role
could delete anything.** `continuum_maintenance` held `GRANT USAGE ON SCHEMA`
and no table privileges at all. A retention job, a right-to-erasure request, or
any purge had no role to run as; only the table owner, via a migration or manual
DBA action.

That is not a tenable end state. Erasure is a real operational duty with a legal
dimension, and "a human runs SQL as the owner" is the least auditable way to
discharge it.

## Decision

**`continuum_maintenance` gets `SELECT, DELETE` on the 21 domain tables.
`continuum_app` never gets `DELETE`.**

This is what the three-role split established in ADR-0001 exists to express.
v1.2 supersedes rather than deletes — `superseded_by` on claims and memories,
promotion stages on mutations — so hard deletion is not part of normal
application behaviour. Making it a separate role makes it a separate, auditable
act, and means a compromised application session cannot destroy history.

`SELECT` is granted alongside `DELETE` because a retention job has to find the
rows before it can remove them.

### Erasure stays tenant-scoped

`continuum_maintenance` is `NOLOGIN NOBYPASSRLS`, like every other operational
role. The tenant policies therefore apply to it exactly as they apply to the
application: a purge runs **inside** a tenant context, with
`app.workspace_id` set, and can only reach that workspace's rows.

There is no cross-workspace sweep, and that is deliberate rather than a
limitation. A right-to-erasure request is per data subject, which in this model
means per workspace. A maintenance role that could delete across every tenant at
once would be a single credential capable of destroying the entire estate, and
would reintroduce exactly the boundary that `NOBYPASSRLS` exists to hold.

### Two tables are excluded, on purpose

| Table | Why |
|---|---|
| `events` | The event store is append-only. `events_append_only` rejects `DELETE` for every role — triggers fire regardless of privilege. A grant here would be a privilege that cannot be exercised, which is worse than no grant: it reads as permission. |
| `workspaces` | Deleting a workspace cascades into the event store, where the append-only trigger raises. Workspace teardown therefore cannot work by cascade today. |

Both exclusions are enforced by an explicit `REVOKE`, not left to the absence of
a `GRANT`, so a later blanket grant cannot silently reintroduce them.

## Consequences

**Positive.** Erasure has a role, and a job that performs it can be granted
exactly that credential and nothing else. The application cannot hard-delete,
so a compromised application session cannot destroy history. Isolation is
unchanged: the erasure role is bound by the same policies as everything else.

**Negative.** A purge must iterate workspaces and set the tenant context for
each, rather than issuing one global statement. This is more work for the caller
and is the intended trade.

**Open question, not resolved here.** Workspace teardown conflicts with the
append-only event store: the cascade cannot complete while the trigger holds.
Deleting a tenant therefore requires deciding what happens to its audit log —
retained under a tombstone, exported and then dropped by a privileged migration,
or the events retained indefinitely with the tenant marked inactive. That is a
data-retention policy question, not a grants question, and it needs its own ADR
before workspace deletion is offered. Until then the grant is withheld rather
than offered and left to fail at the moment someone uses it.

## Verification

`docs/spec/continuum_v1.2_core_schema.derived.verify.sql`, applied to
PostgreSQL 18 + pgvector in CI:

- **24** — exercises all four halves of the claim: `continuum_app` is refused,
  `continuum_maintenance` erases a row in its own workspace, the same role
  cannot reach another workspace's rows, and the other tenant's data survives.
- **25** — `continuum_maintenance` holds no `DELETE` on `events` or
  `workspaces`.

Each was run against both the correct and the defective configuration on a local
PostgreSQL instance carrying the real grant and policy text:

| Configuration | Result |
|---|---|
| `continuum_app` granted `DELETE` | `continuum_app was able to hard-delete a row` |
| `continuum_maintenance` missing `DELETE` | `permission denied for table memories` |
| `continuum_maintenance` made `BYPASSRLS` | `deleted 1 row(s) from another workspace` |
| `DELETE` on `workspaces` granted | `the grant is a lie` |
| Correct configuration | passes |

The third is the one that matters: it shows the tenant-scoping of erasure is
enforced rather than assumed. Flipping one role attribute produces a
cross-workspace deletion, and the assertion catches it.

## Rollback

`git revert`. No persistent database holds Continuum data, so there is nothing
to migrate.

## Provenance

`[DECISION]`. v1.2 does not state a deletion model; it states supersession
semantics, from which the absence of application-level deletion is `[DERIVED]`,
and the assignment of erasure to `continuum_maintenance` is a local decision
made here. Nothing in this ADR may be cited as recovered v1.2 specification
text — `CONT-LOCAL-GOV-001`.
