# Evidence — FND-SPEC-001

## Scope

Work package: `FND-SPEC-001` — Derived reconstruction of the v1.2 core
implementation artifact.

The v1.2 report links a machine-readable companion at
`sandbox:/mnt/data/Continuum_v1.2_Implementation_Specification.md` containing
the full core PostgreSQL DDL, event schema, dependency baseline and Temporal
definitions. That path is ephemeral session storage. The file was generated
during the specification session and never persisted.

This package delivers a **derived replacement**, explicitly labelled as such.

## Search for the original — exhaustive and negative

Seven documents were supplied across the investigation. By SHA-256 they are
**four distinct files**:

| SHA-256 (first 16) | Copies | Document |
|---|---:|---|
| `af4bef0e0409d59a` | 2 | `deepresearchreport.md` (v1.2 normative text) |
| `5a8311c064e42ba3` | 3 | v1.2 PDF — same content, rendered |
| `dc222b7d9b352b9a` | 1 | `Continuum_v1.1.pdf` |
| `52e37fd4e5eb72a8` | 1 | `Continuum1.0.pdf` |

Schema content across the entire corpus:

| Document | `CREATE TABLE` | Tables named |
|---|---:|---:|
| v1.2 (`.md` and PDF) | 1 — `memory_embeddings` | 25 |
| v1.1 | 2 — `knowledge_edges`, `run_events` | 50 |
| v1.0 | 2 — byte-identical to v1.1 | 50 — identical set |

**Three distinct tables of DDL against the 25 that v1.2 names.** All three
surviving copies of the v1.2 specification still contain the dead `sandbox:`
link and the sentence *"Activity timeouts are defined in the downloadable core
artifact"* — they are the documents that point at the missing file, in every
version. The original is not in the corpus and is treated as unrecoverable.

## Deliverables

| File | Role |
|---|---|
| `docs/spec/Continuum_v1.2_Core_Implementation_Artifact.derived.md` | The reconstruction, with per-declaration provenance |
| `docs/spec/continuum_v1.2_core_schema.derived.sql` | Executable DDL |
| `docs/spec/continuum_v1.2_core_schema.derived.verify.sql` | Invariant assertions |
| `.github/workflows/derived-core-schema.yml` | Applies both to PostgreSQL 18 + pgvector in CI |

## Provenance discipline

`CONT-LOCAL-GOV-001` prohibits presenting reconstructed behaviour as recovered
specification text. Every declaration therefore carries exactly one tag:

| Tag | Meaning | Approx. count |
|---|---|---:|
| `[V12]` | Stated directly in v1.2 | ~120 |
| `[V11]` | Carried from the v1.0/v1.1 predecessor | ~45 |
| `[DERIVED]` | Inferred from a cited v1.2 invariant | ~35 |
| `[DECISION]` | No source support; requires ADR | ~30 |

The document is titled and headed **DERIVED**, not "recovered". That distinction
is load-bearing: the artifact was never recovered, and a reader who cites this
document as v1.2 source would be repeating the error the governance rule exists
to prevent.

### Material that made reconstruction tractable

The v1.1/v1.0 predecessor specifications carry typed models that v1.2 omits:
`ClaimStatus`, `EvidenceType`, `Evidence`, `Claim`, `FailureRecord`, and
`ToolCandidate`, plus the universal column rule (*"Every high-volume table should
include: workspace_id, created_at, trace_id where applicable"*) and the
`run_events` table that is the direct ancestor of the v1.2 `events` table.

v1.2 itself constrains far more than its single DDL block suggests: the artifact
manifest JSON Schema fixes the `artifacts` columns, the tool manifest fixes
`tools`/`tool_versions`, the cost model fixes `cost_events`, the router utility
function fixes `model_metrics`, and the memory retrieval query names seven
`memories` columns directly.

## Verification

The reconstruction is executed, not merely written. A local PostgreSQL cluster
could not be started in the review sandbox (`initdb` refuses to run as root, and
no container daemon is available), so verification runs in CI against the real
`pgvector/pgvector:0.8.6-pg18-trixie` image already used by this repository.

Assertions in `continuum_v1.2_core_schema.derived.verify.sql`:

1. PostgreSQL 18+ baseline.
2. All 25 v1.2-named tables exist under `continuum`.
3. `memory_embeddings.embedding` is `vector(512)` with an HNSW cosine index.
4. `continuum.current_workspace_id()` returns `NULL` when unset — fails closed.
5. RLS is both **enabled and forced** on every tenant-scoped table.
6. The event store rejects `UPDATE` and `DELETE`.
7. A risk-4 tool version cannot be inserted with `approval_required = false`.
8. A mutation cannot reach `promoted` with a null approver.
9. Operational roles carry `NOLOGIN NOBYPASSRLS`, even if pre-provisioned.
10. A child row cannot reference a parent owned by another workspace.
11. A promoted tool version cannot lack an immutable image digest.
12. A risk-3/4 execution cannot be recorded without an approval.
13. Built-in agents remain readable under the tenant policy.
14. An oversized JSONB payload is rejected by the `jsonb_256k` domain.
15. `memories.search_tsv` is generated and matches a full-text query.
16. The event hash chain is computed server-side and follows `sequence` order,
    including for several events written inside one transaction.
17. A forged `previous_hash` is rejected rather than silently overwritten.

Assertions 6–17 are the point of the exercise. v1.2 states these as hard gates
in prose; the reconstruction turns them into database constraints that fail
loudly rather than depending on application code to remember.

Assertion 10 is the sharpest of them: it inserts an embedding in workspace A
pointing at a memory in workspace B. The v1.2 verbatim single-column foreign key
accepts that row. The derived composite constraint rejects it.

## Gate evidence

### FND-SPEC-G1 — labelled reconstruction with provenance
- `docs/spec/Continuum_v1.2_Core_Implementation_Artifact.derived.md` §0, §8

### FND-SPEC-G2 — executable against PostgreSQL 18 + pgvector
- `docs/spec/continuum_v1.2_core_schema.derived.sql`
- `.github/workflows/derived-core-schema.yml`

### FND-SPEC-G3 — invariants enforced by the schema
- `docs/spec/continuum_v1.2_core_schema.derived.verify.sql` assertions 4–17

### FND-SPEC-G4 — decisions enumerated, gap not silently closed
- Artifact §8 lists every `[DECISION]` requiring ADR approval
- `docs/implementation/source-gaps.json` — `SRC-001` remains `open`

## Review round: 11 findings, all accepted

Automated review of the first commit returned eleven P2 findings. All were
verified against the source and all were correct. Nine were schema or document
defects; two were over-claims in this package's own gate descriptions.

| # | Finding | Resolution |
|---:|---|---|
| 1 | Single-column FKs let a child reference a parent in another workspace | Composite `(workspace_id, id)` FKs on the tenant-scoped pairs |
| 2 | `approved_by` proves a user exists, not that they approved | Gate G3 corrected; the residual authorization boundary is recorded as a decision |
| 3 | Event column **types** tagged `[V12]` when v1.2 gives names only | Split into `[V12 name]` + `[DERIVED shape]` |
| 4 | `bigserial` default needs sequence `USAGE`, not just table `INSERT` | `GRANT USAGE ON SEQUENCE` added |
| 5 | Nothing required an approval before a risk-3/4 *execution* | Cross-table trigger on `tool_executions` |
| 6 | Decision list was categorical, not exhaustive | Generated mechanically from `[DECISION]` tags |
| 7 | A promoted tool version could have a null `image_digest` | CHECK requiring `sha256:<64 hex>` when promoted |
| 8 | `metric_name` differed between the `.md` and the `.sql` | Aligned; nullable form would have voided the UNIQUE |
| 9 | Built-in agents (`workspace_id IS NULL`) invisible under the uniform policy | Separate read/write policies for `agents`, `agent_versions` |
| 10 | Role attributes not reasserted when the role pre-exists | `ALTER ROLE … NOLOGIN NOBYPASSRLS` every run, plus an assertion |
| 11 | Temporal section pointed at an uncommitted document | Definitions reproduced in full |

### Finding 1 is a defect in the source, not the reconstruction

v1.2's own `memory_embeddings` DDL declares `memory_id REFERENCES memories(id)`
and `workspace_id REFERENCES workspaces(id)` as **independent** constraints.
Referential integrity does not require the referenced memory to belong to the
referencing row's workspace, so the published DDL permits an embedding in
workspace A to point at a memory in workspace B — while still satisfying the RLS
predicate on the embedding row itself. That contradicts the v1.2 hard gate of
zero cross-workspace access.

The verbatim block is left unmodified and the composite constraint is added
immediately after it as an explicit `ALTER TABLE`, so the reproduced source text
stays intact and the hardening is visible as a derived addition.

### Findings 2 and 5 were over-claims in this package

`FND-SPEC-G3` originally asserted that "risk-3/4 tools require approval" and
that promotion required "a human approver". Neither was true as written: the
`tool_versions` CHECK recorded only that approval was *required*, and
`approved_by` is a foreign key that proves a user row exists. Finding 5 is now
genuinely enforced by a trigger. Finding 2 cannot be closed in-schema without an
authenticated approval path, so the gate text was corrected to say what the
constraint actually provides rather than what it was claimed to provide.

## What this package deliberately does not do

It **does not close `SRC-001`**. Issue #2's second close criterion requires
reconstructed detail to be *"approved through an ADR with traceability to
v1.2"*. This package supplies the traceability. The ADRs and the human approval
are separate and outstanding.

It **does not unblock `FND-DB-DOMAIN`**, which stays `blocked` until those
decisions are approved.

The highest-priority decision is the **event hash canonicalisation** (artifact
§4.2). The original byte layout is unknown, and changing it after any event is
written invalidates every existing chain — so it must be fixed by ADR before the
event store takes its first write.

## Second round: an independently produced candidate DDL

A second reconstruction of the same missing artifact was supplied for
comparison. Rather than review it by reading, it was applied to the same
PostgreSQL 18 + pgvector image in CI alongside a probe that exercised its event
store and tenant isolation. Three defects surfaced, all of them by execution:

| # | Defect | How it fails |
|---:|---|---|
| 1 | `SECURITY DEFINER` hash trigger calls `digest()` with `search_path` set to `pg_catalog, continuum` | `pgcrypto` installs `digest()` into `public`, which that path excludes. The function is unreachable, so the event store cannot accept a single row. |
| 2 | 25 tenant tables take `workspace_id` from a session GUC with no default and no fallback | `not_null_violation` on every insert that does not set the GUC first. |
| 3 | Chain head selected by `ingested_at` | Three events written in one transaction share one `now()`, so the tiebreak falls to a random UUID. The chain links, but its order is not reconstructible. |

Defect 1 is the instructive one: it is invisible to a reader, because the
function body and the `search_path` hardening are individually correct and are
declared far apart. Only executing it shows that the combination has no
`digest()` in scope.

### What the candidate got right, and what was taken from it

Four of its ideas were genuinely better than the first reconstruction and are
adopted here:

| Adopted | Why |
|---|---|
| `continuum.jsonb_256k` domain on `events.payload`, `evidence.payload`, `artifacts.metadata` | v1.2 bounds payload size in prose; the first reconstruction left it unbounded. |
| `search_tsv` as `GENERATED ALWAYS AS (to_tsvector('english', content)) STORED` | The column was declared and indexed but never populated — the index could not match anything. |
| Server-side `events_prepare_hash()` | Moves canonicalisation off the application, where every writer had to agree on it independently. |
| `events_reject_truncate` | `TRUNCATE` bypasses row-level triggers, so append-only was enforceable only against `UPDATE`/`DELETE`. |

Each was reimplemented rather than copied, so that defects 1–3 are not carried
across: the hash trigger uses the builtin `pg_catalog.sha256(bytea)` — no
extension, hardening preserved — and orders the chain head by the `bigserial`
`sequence` under an advisory lock rather than by timestamp.

The candidate's level-4 tool comment was checked against this schema and
required no change: both files enforce the same rule (risk ≥ 3 requires
approval), and the comment warns against a table-level ban on *active* level-4
tools that this schema never imposed.

## Safety and rollback

No production schema, migration, cloud resource, or Temporal namespace is
created. The CI job applies the schema to a throwaway container database and
discards it. Rollback is a Git revert with no data implications.
