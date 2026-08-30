# ADR-0006: Every tenant-scoped row names its workspace, and every foreign key names it too

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-08-30
- **Related:** `FND-SPEC-001`; ADR-0001 (bootstrap boundary); ADR-0003 (no deletion of domain rows)
- **Closes:** deferred item 5 of ADR-0003; decision 8 of the companion document

## Context

v1.2 states the tenancy gate as **zero cross-workspace access across 10,000+
attempts**. The reconstruction enforced it with Row Level Security: `ENABLE` and
`FORCE` on every table carrying `workspace_id`, a policy comparing that column
against `continuum.current_workspace_id()`, and assertion 23 proving the
behaviour as `continuum_app` rather than reading a flag off `pg_class`.

That is not enough, and the reason is documented PostgreSQL behaviour:

> Referential integrity checks, such as unique or primary key constraints and
> foreign key references, always bypass row security to ensure that data
> integrity is maintained.

RI checks run with row security suspended, so that a foreign key cannot be
defeated by a policy. The consequence runs the other way too: a tenant that
cannot *read* a row can still *name* it in a foreign key. Sixteen foreign keys
in the schema named a tenant-scoped parent by `id` alone, and each was an
opening.

ADR-0003 deferred five of them and called them "no longer urgent, still a
defect" — reasoning that the hazard was `ON DELETE CASCADE` reaching across
tenants, and that ADR-0003 had left no role holding `DELETE`. **The premise was
wrong.** Creating a cross-tenant reference never required `DELETE`. It requires
`INSERT`, which `continuum_app` has. Reproduced against the unfixed schema, as
`continuum_app` with `app.workspace_id` set to workspace B:

```text
A run visible to B: 0                      -- RLS working exactly as intended
B failure -> A run:            ACCEPTED
B agent_version -> A agent:    ACCEPTED
```

The tenant could not see the parent and referenced it anyway. Nothing in the
verification suite covered this: assertion 10 tested the one composite key
v1.2's own DDL implies, and every other FK assertion ran as the owner, where the
RLS interaction never arises.

## The conflict this forced

Nine tables declared `workspace_id` nullable, with `NULL` documented as a
built-in shared by every tenant.

A composite foreign key cannot express *"the parent is mine, or the parent is
global."* Worse, under `MATCH SIMPLE` — the default — a `NULL` in **any**
referencing column skips the check **entirely**. A nullable `workspace_id` is
therefore not a feature sitting alongside tenant-qualified keys; it is the
single thing that reopens the hole they close.

The two could not both stand. What settled it:

- The shared catalogue was never v1.2. `null = built-in` is tagged `[DERIVED]`,
  and its visibility rule was decision 8 — proposed, never approved.
- It was half-built. Only `agents` and `agent_versions` ever got the read policy
  admitting `NULL`. On the other seven the uniform predicate
  `workspace_id = current_workspace_id()` is never true for a `NULL`, so those
  rows were invisible to every tenant and un-insertable by `continuum_app`. The
  capability existed in the column definition and nowhere else.
- Keeping it would have required a constraint trigger per relationship,
  replacing a declarative constraint the planner enforces with procedural code
  that has to be got right sixteen times.

## Decision

**Every tenant-scoped row names its workspace, and every foreign key to a
tenant-scoped parent names it too.**

### 1. `workspace_id` is `NOT NULL` wherever it appears

On `agents`, `agent_versions`, `model_metrics`, `tools`, `tool_versions`,
`evaluations`, `evaluation_results`, `mutations` and `mutation_evaluations`. The
shared catalogue is withdrawn; a built-in becomes a row seeded per workspace.

This also repairs `UNIQUE (workspace_id, name)` on `agents` and `tools`. With a
nullable column those keys constrained nothing across built-ins, because `NULL`
values are distinct in a unique index — any number of built-ins could share a
name.

### 2. All sixteen foreign keys are tenant-qualified

Not the five ADR-0003 enumerated. Those five were the cascading ones; the other
eleven — mostly `run_id` — carry the same defect and were simply never listed.
Six parents gained `UNIQUE (workspace_id, id)` to be referable this way, joining
the four that already had it.

`memory_embeddings` keeps the composite constraint added outside its verbatim
v1.2 block, and drops the single-column `memory_id` FK that block declares: both
its columns are `NOT NULL`, so the composite checks everything the single-column
key checked and the tenancy besides.

### 3. `ON DELETE SET NULL` names its column

Seven of these keys are `ON DELETE SET NULL`. Written bare, `SET NULL` nulls
**every** referencing column — including `workspace_id`, which is `NOT NULL` on
all seven children and is the RLS discriminator:

```sql
FOREIGN KEY (workspace_id, run_id)
    REFERENCES continuum.runs (workspace_id, id) ON DELETE SET NULL (run_id)
```

`events.run_id` is the exception and stays `NO ACTION`: the event store is
append-only, so `SET NULL` would issue the `UPDATE` that
`events_reject_mutation` blocks.

### 4. The uniform RLS predicate covers every tenant table

`agents` and `agent_versions` join the strict predicate. The policy admitting
`workspace_id IS NULL` is deleted rather than left in place — with the column
`NOT NULL` the disjunct can never be true, and a policy clause that cannot be
true is decoration of exactly the kind that let a tautological policy pass a
reading review here before.

## Consequences

- A built-in agent or tool is now seeded per workspace. Nothing in v1.2 asks for
  cross-tenant sharing, but this is a real capability being removed, and any
  later shared catalogue must come back through its own ADR — with a mechanism
  that survives `MATCH SIMPLE`, not a nullable column.
- Seven referencing-side indexes were added, because a referential action makes
  PostgreSQL search the child by the FK's own columns. Nothing may delete a
  domain row today, so these buy nothing yet; they exist so the actions already
  declared are not a latent sequential scan.
- Verification fixtures that relied on a nullable `workspace_id` now name one.

## Verification

`docs/spec/continuum_v1.2_core_schema.derived.verify.sql`, applied to
PostgreSQL 18 + pgvector in CI:

- **13** — inverted, not deleted. It required the `IS NULL` disjunct; it now
  rejects any policy carrying one, so the withdrawn capability cannot return
  quietly. The numbering downstream is unchanged.
- **31** — a cross-tenant reference on a cascading relationship is rejected, and
  the same-workspace reference is still accepted. A constraint that rejects
  everything is not isolation, it is breakage.
- **32** — the same, executed as `continuum_app`. This is the assertion that
  matters: it first proves the premise (B cannot see A's run), then proves the
  reference is refused. Assertion 31 runs as the owner, where RLS is never
  evaluated.
- **33** — structural. Every foreign key in the schema ties the child's own
  `workspace_id` to the parent's, **matched by ordinal**. This is the only one
  of the three that constrains a foreign key nobody has written yet.

  The ordinal match is not pedantry. Asking merely whether the parent's
  `workspace_id` appears somewhere in `confkey` accepts
  `FOREIGN KEY (id, run_id) REFERENCES continuum.runs (workspace_id, id)`,
  which a caller satisfies by putting another tenant's workspace UUID in `id`.
  Reproduced: with that constraint in place, `continuum_app` scoped to
  workspace B inserted a `cost_events` row referencing workspace A's run.
- **34** — `workspace_id` is `NOT NULL` on every base table carrying it.
- **35** — a parent delete nulls `run_id` and leaves `workspace_id` intact.

Every assertion was run against a deliberately broken schema and observed to
fail before being trusted:

| Mutation | Assertion that caught it |
|---|---|
| `agent_versions.agent_id` reverted to a single-column FK | 31 — `cross-workspace parent reference was accepted on a cascading FK` |
| `failures.run_id` reverted to a single-column FK | 32 — `continuum_app referenced another workspace's run through the RI bypass` |
| An unqualified FK added by a later `ALTER TABLE` | 33 — `foreign key(s) not tying the child workspace_id to the parent's: continuum.cost_events.bad_fk -> continuum.runs` |
| An FK naming the parent's `workspace_id` from the child's `id` | 33 — `... continuum.cost_events.cost_events_swapped_fk -> continuum.runs` |
| `tools.workspace_id` made nullable again | 34 — `workspace_id is nullable on: tools` |
| `SET NULL` written without its column list | 35 — `ON DELETE SET NULL tried to null workspace_id: the constraint is missing its column list` |
| `CASCADE` written in place of `SET NULL` | 35 — `the child row did not survive its parent; SET NULL behaved as CASCADE` |
| The `IS NULL` disjunct restored to a read policy | 13 — `policy admits a workspace-less row: agents.agents_read` |

Assertion 33's ordinal match was added in review: the first version tested
membership, and Codex found the swapped-ordinal constraint that satisfies it
while leaving the hole open. The finding was reproduced before it was fixed.

Assertion 35 was rewritten because of what its first negative control showed:
the bare `SET NULL` does not produce a wrongly-nulled row, it produces a
not-null violation, so the value comparison the assertion ended on was
unreachable. The check now names that failure mode where it actually occurs.

## Provenance

This ADR does not add to what v1.2 states. The hard gate of zero cross-workspace
access is `[V12]`; the composite-key encoding of it is `[DERIVED]`; making
`workspace_id` `NOT NULL` and withdrawing the shared catalogue is
`[DECISION: ADR-0006]`. Nothing here may be cited as recovered v1.2
specification text.
