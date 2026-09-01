# ADR-0010: The residual schema declarations

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-09-01
- **Related:** `FND-SPEC-002`; ADR-0006 (tenant-scoped rows name their workspace)
- **Closes:** the remaining `[DECISION]` declarations enumerated in the companion document

## Context

The companion document enumerates 31 `[DECISION]` declarations in
`continuum_v1.2_core_schema.derived.sql` — generated from the tags in the file,
so the list cannot drift from what executes. Each is a declaration v1.2 does not
support, and each needs approval before it is relied upon.

Most are conventional: a `status` column with a default, an `updated_at`, a
nullable `started_at`/`completed_at` pair, a `jsonb` default. Approving those
individually would produce twenty-six near-identical records and obscure the few
that matter.

**Five are not conventional.** Each closes a domain — it constrains what can
ever exist in the column — so changing it later is a migration against live data
rather than an edit. Those get their own reasoning.

## Decision

### The five that close a domain

**1. `CREATE EXTENSION IF NOT EXISTS citext`**

An extension dependency, so it constrains where the database can run: a managed
Postgres without `citext` cannot host this schema. It exists for exactly one
column, `users.email UNIQUE`. Case-sensitive email uniqueness would let
`A@x.com` and `a@x.com` both exist, which is an identity defect, not a
formatting one. The alternative — `text` plus a `lower(email)` unique index —
avoids the extension but moves correctness into every query that looks a user
up by address. `citext` puts it in the type. **Accepted.**

**2. `continuum.memory_type` ENUM values**

The closed set of memory kinds. v1.2 describes the memory lifecycle and
retrieval extensively but never enumerates the kinds, so the value list is
inferred from that prose. **Accepted, with the migration cost named:** adding a
value is cheap (`ALTER TYPE ... ADD VALUE`), removing or renaming one is not,
and the retrieval scoring reads this column. Prefer adding.

**3. `continuum.run_status` ENUM values** — `accepted`, `running`, `succeeded`,
`failed`, `cancelled`.

The closed lifecycle of a run. This is the state machine every workflow reports
into, and `runs.status` is what an operator reads to know what happened. The set
is deliberately small and terminal-state-complete: every run ends in
`succeeded`, `failed` or `cancelled`, with no "unknown" escape hatch that would
let a lost run look like a finished one. **Accepted.**

**4. `agents UNIQUE (workspace_id, name)`**

A real uniqueness constraint, and one ADR-0006 changed the meaning of. While
`workspace_id` was nullable, `NULL` values are distinct in a unique index, so
any number of built-in agents could share a name and the constraint said almost
nothing. With the column `NOT NULL` it means what it reads as: one agent per
name per workspace. **Accepted, and now enforceable.**

**5. `claim_evidence.weight CHECK (weight BETWEEN 0 AND 1)`**

A bound on a value the claim-scoring model reads. Unbounded, a single
mis-scaled weight (say 100 where 1.0 was meant) would dominate every claim it
touches and the arithmetic would give no sign of it. The bound makes the
mis-scaling a write-time rejection instead of a silently wrong confidence.
**Accepted.** The column stays nullable — absent evidence weight is a real
state, distinct from zero weight.

### The remaining twenty-six, as a class

Column defaults and conventional shapes with no source support and no
consequence beyond convention:

| Family | Declarations |
|---|---|
| `status text NOT NULL DEFAULT '…'` | `users`, `workspaces`, `agents`, `tools`, `tool_executions`, `evaluations` |
| `updated_at timestamptz NOT NULL DEFAULT now()` | `users`, `workspaces` |
| nullable `started_at` / `completed_at` | `runs`, `evaluations` |
| `jsonb NOT NULL DEFAULT '{}'::jsonb` | `agent_versions.config`, `evaluation_results.detail` |
| descriptive / audit columns | `users.display_name`, `users.email`, `runs.created_by`, `workspace_members.role`, `model_metrics` window columns, `evaluation_results.passed`, `evaluation_results.metric_name` |

**Accepted as a class.** Each is a default or a nullability choice that can be
changed by a routine migration without reinterpreting existing rows. None closes
a domain, none is read by scoring or routing logic, and none would change
meaning if revisited.

The `status` columns are worth one note: they are `text` with a default rather
than ENUMs, unlike `run_status`. That is deliberate — a run's lifecycle is a
state machine worth closing, whereas an agent or tool being `active` is a flag
whose value set is likely to grow, and growing a `text` column costs nothing.

## Consequences

- The `[DECISION]` enumeration in the companion document is fully covered. A new
  `[DECISION]` tag added to the schema is, by construction, not covered by this
  ADR and needs its own.
- The five reasoned declarations are the ones to revisit first if the schema is
  ever reopened; the twenty-six are not load-bearing.

## Verification

The enumeration is generated from the `[DECISION]` tags in
`continuum_v1.2_core_schema.derived.sql`, so it cannot drift from the executable
schema — that generation is the check. Assertions already covering the five:

- `citext` and both ENUM sets — assertion 2 (all 25 tables present, applied
  against real PostgreSQL 18; a missing extension or ENUM fails the apply).
- `agents UNIQUE (workspace_id, name)` — assertion 34 proves `workspace_id` is
  `NOT NULL`, which is what makes the constraint bite.
- `weight BETWEEN 0 AND 1` — the schema applies, so the CHECK is present; a
  bound that rejects nothing would need its own assertion, which
  `FND-DB-DOMAIN` should add when it writes rows.

## Provenance

Every declaration approved here is `[DECISION: ADR-0010]`. None is v1.2 text,
and none may be cited as recovered specification.
