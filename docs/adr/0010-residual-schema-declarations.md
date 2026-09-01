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
individually would produce twenty-five near-identical records and obscure the
few that matter.

**Six are not conventional.** Each closes a domain — it constrains what can
ever exist in the column — so changing it later is a migration against live data
rather than an edit. Those get their own reasoning.

The test for membership is the declaration, not the column's subject matter: a
`CHECK` closes a domain even when it guards a column that otherwise reads as
bookkeeping. `model_metrics.sample_count` was approved as conventional in the
first draft of this ADR on that mistake, and is reasoned below.

## Decision

### The six that close a domain

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

**5. `model_metrics.sample_count integer NOT NULL CHECK (sample_count >= 0)`**

A `CHECK` that excludes half the integer domain, and therefore not the
default-or-nullability choice the class approval below describes. It also fails
the second half of that claim: `model_metrics` is the per-tenant observation
table routing and scoring read, so a sample count is an input to model
selection, not bookkeeping beside it.

The bound is worth having on its own terms — a negative sample count is
meaningless, and a metric row carrying one would propagate into any average
weighted by it. **Accepted.** Note what it does *not* constrain: zero is legal,
so a window with no samples is representable and a consumer must still decide
what a zero-sample metric means rather than assuming the bound rules it out.

**6. `claim_evidence.weight CHECK (weight BETWEEN 0 AND 1)`**

A bound on a value the claim-scoring model reads. Unbounded, a single
mis-scaled weight (say 100 where 1.0 was meant) would dominate every claim it
touches and the arithmetic would give no sign of it. The bound makes the
mis-scaling a write-time rejection instead of a silently wrong confidence.
**Accepted.** The column stays nullable — absent evidence weight is a real
state, distinct from zero weight.

### The remaining twenty-five, as a class

Column defaults and conventional shapes with no source support and no
consequence beyond convention:

| Family | Declarations |
|---|---|
| `status` with a default (`tool_executions` without) | `users`, `workspaces`, `agents`, `tools`, `tool_executions`, `evaluations`, `runs` |
| `updated_at timestamptz NOT NULL DEFAULT now()` | `users`, `workspaces` |
| nullable `started_at` / `completed_at` | `runs`, `evaluations` |
| `jsonb NOT NULL DEFAULT '{}'::jsonb` | `agent_versions.config`, `evaluation_results.detail` |
| `name text NOT NULL` | `workspaces`, `agents` |
| descriptive / audit columns | `users.display_name`, `users.email`, `runs.created_by`, `workspace_members.role`, `model_metrics.window_start`, `model_metrics.window_end`, `evaluation_results.passed`, `evaluation_results.metric_name` |

**Accepted as a class.** Each is a default or a nullability choice that can be
changed by a routine migration without reinterpreting existing rows. None
carries a `CHECK`, none closes a domain, and none would change meaning if
revisited. The families above enumerate all twenty-five; a declaration that is
not in one of them is not covered by this class approval.

The `status` columns are worth one note: they are `text` with a default rather
than ENUMs, unlike `run_status`. That is deliberate — a run's lifecycle is a
state machine worth closing, whereas an agent or tool being `active` is a flag
whose value set is likely to grow, and growing a `text` column costs nothing.

## Consequences

- The `[DECISION]` enumeration in the companion document is fully covered. A new
  `[DECISION]` tag added to the schema is, by construction, not covered by this
  ADR and needs its own.
- The six reasoned declarations are the ones to revisit first if the schema is
  ever reopened; the twenty-five are not load-bearing.

## Verification

Each claim below is checked by something that has been observed to fail when the
thing it covers is broken. The previous draft of this section cited assertions
that did not cover what it said they did — assertion 2 proves the 25 tables
exist, which a renamed ENUM label survives; assertion 34 proves
`agents.workspace_id` is `NOT NULL`, which is what makes the unique constraint
bite and not evidence that the constraint is there. "The schema applies" is not
a check on any of this.

| Claim | Check | Observed to fail when |
|---|---|---|
| The enumeration cannot drift from the schema | `scripts/check_decision_coverage.py` compares location and declaration text pairwise, not totals | a row is renamed, two rows are transposed, or a tag moves between columns — count unchanged in every case |
| `memory_type` / `run_status` carry exactly these labels | verify assertion 36, over `pg_enum` in `enumsortorder` | a label is renamed (`failure` → `failures`) or added (`run_status` gains `paused`) |
| `agents UNIQUE (workspace_id, name)` exists, in that order | verify assertion 37, over `pg_constraint` with `WITH ORDINALITY` | the constraint is dropped, or replaced with `(name, workspace_id)` |
| `weight BETWEEN 0 AND 1` rejects rather than exists | verify assertion 38, by attempting the writes | the bound is dropped, or weakened to `>= 0` |

Assertion 38 exercises both ends and confirms `NULL` stays legal. A `CHECK` that
is present and vacuous is a defect this repository has already shipped once:
`CHECK (stage <> 'promoted' OR digest ~ '...')` passed on `NULL`, because
`NULL ~ pattern` is `NULL` and `CHECK` rejects only `FALSE`. Asserting the
constraint's presence would have reproduced that.

`citext` remains covered by the apply: the extension is a hard dependency, so a
schema without it fails to create `users.email` rather than creating it wrongly.
That is the one item on this list where applying really is the check.

## Provenance

Every declaration approved here is `[DECISION: ADR-0010]`. None is v1.2 text,
and none may be cited as recovered specification.
