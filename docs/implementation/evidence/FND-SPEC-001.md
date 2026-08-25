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
8. A mutation cannot reach `promoted` without a human approver.

Assertions 6–8 are the point of the exercise. v1.2 states these as hard gates in
prose; the reconstruction turns three of them into database constraints that
fail loudly rather than depending on application code to remember.

## Gate evidence

### FND-SPEC-G1 — labelled reconstruction with provenance
- `docs/spec/Continuum_v1.2_Core_Implementation_Artifact.derived.md` §0, §8

### FND-SPEC-G2 — executable against PostgreSQL 18 + pgvector
- `docs/spec/continuum_v1.2_core_schema.derived.sql`
- `.github/workflows/derived-core-schema.yml`

### FND-SPEC-G3 — invariants enforced by the schema
- `docs/spec/continuum_v1.2_core_schema.derived.verify.sql` assertions 4–8

### FND-SPEC-G4 — decisions enumerated, gap not silently closed
- Artifact §8 lists every `[DECISION]` requiring ADR approval
- `docs/implementation/source-gaps.json` — `SRC-001` remains `open`

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

## Safety and rollback

No production schema, migration, cloud resource, or Temporal namespace is
created. The CI job applies the schema to a throwaway container database and
discards it. Rollback is a Git revert with no data implications.
