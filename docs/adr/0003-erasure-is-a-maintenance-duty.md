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

### Erasure is statement-scoped to a workspace — and that is a weaker claim than it sounds

`continuum_maintenance` is `NOLOGIN NOBYPASSRLS`, like every other operational
role, so the tenant policies apply to it exactly as they apply to the
application: every statement it issues is confined to the workspace named by
`app.workspace_id`.

**That bounds each statement. It does not bound the session's choice of
workspace.** `app.workspace_id` is an unrestricted custom GUC set by the caller,
so a maintenance-capable session can select any workspace it likes, and a
compromised maintenance credential can iterate workspace ids and erase the
estate one transaction at a time. `NOBYPASSRLS` makes that loud and sequential
rather than a single statement; it does not make it impossible.

This ADR does not close that gap, and it should not be read as claiming to. The
real control is that the workspace context be assigned by a trusted
authorization boundary — a session broker, or a `SECURITY DEFINER` entry point
that derives the workspace from an authenticated principal — rather than
accepted from the role doing the deleting. That is an application-architecture
decision outside this schema, and it is recorded here as a **residual risk**
rather than papered over.

What the tenant scoping does buy, concretely: no single statement can span
tenants, a purge is auditable per workspace, and an accidentally over-broad
`WHERE` clause cannot reach beyond the workspace in context.

### Seven tables are excluded, on purpose

| Table | Why |
|---|---|
| `events` | Append-only. `events_append_only` rejects `DELETE` for every role — triggers fire regardless of privilege. A grant here would be a privilege that cannot be exercised, which is worse than no grant: it reads as permission. |
| `workspaces` | Deleting a workspace cascades into the event store, where that trigger raises. Teardown cannot work by cascade today. |
| `runs` | `events.run_id` references `runs(id)` with the default `NO ACTION`, and the referencing event can be neither deleted nor cleared. A purge of any run that has recorded an event raises a foreign-key violation, so the grant would be exercisable only for runs that never emitted one. |
| `agents`, `tools`, `evaluations`, `mutations` | Each parents a child whose foreign key names it by `id` alone. **PostgreSQL applies referential actions without evaluating the child's RLS policy**, so an `ON DELETE CASCADE` from one of these deletes another tenant's rows silently. |

All seven are enforced by explicit `REVOKE`, not by absence of a `GRANT`, so a
later blanket grant cannot reintroduce any of them.

`continuum_maintenance` is also **not** granted `SELECT` on `users`. That table
is not workspace-scoped and carries email and display name, so reading it would
give a job scoped to one tenant sight of every person in the database — exactly
the reach this ADR says erasure does not have.

#### The cascade exclusion is a real breach, reproduced

The last group is not theoretical. A child in workspace B may reference a parent
in workspace A, because the foreign key constrains only `id`:

```
tenant B rows before:                                     1
maintenance, scoped to workspace A only, deletes A's agent  DELETE 1
tenant B rows after:                                      0
```

One tenant's maintenance job destroyed another tenant's data, with RLS enabled
and forced, without the policy ever being evaluated. With `DELETE` revoked on
the parent the same attempt returns `permission denied for table agents` and the
row survives.

This is a **pre-existing defect in the reconstruction** — the single-column
foreign keys predate this ADR — but granting `DELETE` is what would make it
reachable. Withholding the privilege is therefore the safe interim, not the
fix.

## Consequences

**Positive.** Erasure has a role, and a job that performs it can be granted
exactly that credential and nothing else. The application cannot hard-delete,
so a compromised application session cannot destroy history. Isolation is
unchanged: the erasure role is bound by the same policies as everything else.

**Negative.** A purge must iterate workspaces and set the tenant context for
each, rather than issuing one global statement. This is more work for the caller
and is the intended trade.

**Follow-up, required before those exclusions can be lifted.** The foreign keys
naming a tenant-scoped parent by `id` alone must be qualified by `workspace_id`,
in exactly the way `claim_evidence` and `memory_embeddings` already are —
`REFERENCES parent (workspace_id, id)`. That requires a `UNIQUE (workspace_id,
id)` on each parent and touches `agent_versions.agent_id`,
`tool_versions.tool_id`, `evaluation_results.evaluation_id`,
`mutation_evaluations.mutation_id` and `.evaluation_id`. It is a schema change
larger than this ADR's scope and gets its own change; until then those parents
stay un-erasable.

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
- **25** — `continuum_maintenance` holds no *effective* `DELETE` on any of the
  seven excluded tables, still holds it on `memories` so erasure is not
  decorative, and cannot read `users`.

Each was run against both the correct and the defective configuration on a local
PostgreSQL instance carrying the real grant and policy text:

| Configuration | Result |
|---|---|
| `continuum_app` granted `DELETE` | `continuum_app was able to hard-delete a row` |
| `continuum_maintenance` missing `DELETE` | `permission denied for table memories` |
| `continuum_maintenance` made `BYPASSRLS` | `deleted 1 row(s) from another workspace` |
| `DELETE` on a cascade-unsafe parent | `holds effective DELETE on {tools}` |
| `DELETE` inherited via another role | `holds effective DELETE on {runs}` |
| `SELECT` on `users` granted | `a job scoped to one tenant would see every person` |
| `DELETE` on `memories` withheld | `erasure is not possible` |
| Correct configuration | passes |

Assertion 25 uses `has_table_privilege`, not `role_table_grants`: the latter
lists only *direct* grants, so a privilege inherited from another role or
granted to `PUBLIC` would satisfy it while the role still holds the effective
permission. The inherited-grant row above is that difference, demonstrated.

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
