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
18. `TRUNCATE` on the event store is rejected (it bypasses row-level triggers,
    so assertion 6 alone does not establish append-only).
19. The stored `event_hash` is reproducible by an independent verifier running
    under a non-UTC session `TimeZone`.
20. `payload_artifact_id` is covered by the hash.
21. The ordering value has no column default, and the chain-head lookup is
    indexed.
22. The hash layout is versioned per row, the version has no column default,
    and the version is itself hashed.
23. Tenant isolation holds **in behaviour**, tested as `continuum_app` rather
    than as the superuser: own rows visible, another tenant's rows not, a
    cross-tenant write rejected, built-in agents readable, and no rows at all
    when the tenant context is unset.
24. No operational role can delete a domain row — the application role refused
    behaviourally, and no *effective* `DELETE` (inherited or `PUBLIC` included)
    for either operational role on any of the 25 tables.
25. The artifact retention contract v1.2 specifies is intact: exactly the five
    retention classes, a nullable `delete_after`, a `NOT NULL` retention class.
26. The event payload shape is closed and fails closed: an unregistered
    `event_type` rejected, an unregistered key rejected, a well-formed payload
    accepted (ADR-0004).
27. Bulk content cannot be inlined into an event; `events.payload` carries the
    tightened 8 KiB domain.
28. The v1.2 retention schedule (7 / 90 / 365 days) is applied to the bounded
    classes; a held class cannot be given an expiry, a bounded class cannot
    escape one (ADR-0005).
29. Retention is a ratchet: a `legal_hold` artifact cannot be downgraded to
    `ephemeral`; strengthening still works.
30. Expiry eligibility is structural: an expired artifact is offered, held and
    unexpired ones never are, and one already recorded as removed drops out.

Plus a concurrent-writer test that cannot be expressed in a single psql script:
`scripts/verify_event_chain_concurrency.sh` runs four writers inserting into one
workspace as separate autocommit statements and asserts the chain is intact in
`sequence` order.

Assertions 6–30 are the point of the exercise. v1.2 states these as hard gates
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
- `docs/spec/continuum_v1.2_core_schema.derived.verify.sql` assertions 4–30
- `scripts/verify_event_chain_concurrency.sh` — concurrent-writer chain integrity

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

## Third round: six findings on the server-side hash chain

Automated review of the adopted hash trigger returned six findings, two of them
P1. All six were verified against the source and all six were correct. They are
worth recording because five of the six are defects that only appear under
conditions a single-session test does not create.

| # | Finding | Verified how | Resolution |
|---:|---|---|---|
| 1 | `sequence` is allocated by the `bigserial` default, which is evaluated while the tuple is built — before the trigger takes the advisory lock | Reproduced: 8 concurrent writers, 320 events, **6 backward links** | Default dropped; the trigger allocates inside the lock |
| 2 | `jsonb_build_object` serialises `timestamptz` through the *session* `TimeZone`, so the same instant hashes differently per writer | Assertion 19 fails against the previous trigger | `occurred_at` rendered as explicit UTC text |
| 3 | `payload_artifact_id` was not hashed, so an offloaded payload could be repointed with the chain still valid | Assertion 20 fails against the previous trigger | Added to the canonical object |
| 4 | Companion §4.2 described a different layout entirely (delimiter-concatenated, payload digest, 64-zero genesis) | Read against the SQL | §4.2 rewritten to the executed layout, and assertion 19 re-implements it independently so the two cannot drift again |
| 5 | No assertion executed `TRUNCATE` | Assertion 18 fails with the trigger dropped | Assertion 18 added |
| 6 | No index served `WHERE workspace_id = ? ORDER BY sequence DESC` | Read against `pg_indexes` | `events_workspace_sequence_idx` added |

A seventh defect was found while fixing these, in this package's own document
rather than in the review: `payload_artifact_id` was tagged `[V12] field` in the
artifact. v1.2 never names that column — only the ">256 KiB … referenced by
UUID and SHA-256" rule that motivates it. Tagging an invented column as
recovered source is precisely what `CONT-LOCAL-GOV-001` prohibits, so the tag is
now `[DERIVED] column; [V12] >256 KiB offload rule`.

### The race was reproduced, not reasoned about

Finding 1 is the one that matters, and it is invisible to every test that writes
events one at a time. Restoring the column default and running eight concurrent
writers produced six events whose `previous_hash` pointed at a *later* event —
a ledger that verifies as broken despite the advisory lock doing exactly what it
was written to do. With the allocation moved inside the lock, the same load
produces an intact chain.

`sequence` is now also part of the hashed canonical form. The lock makes the
chain correct as it is written; hashing the position makes reordering detectable
afterwards, which is what a tamper-evident ledger is for.

### Local verification

PostgreSQL 18 with pgvector is not available in the review sandbox, and CI
remains the authority for the full schema. The new logic was nonetheless
exercised locally against PostgreSQL 16 on a reduced schema carrying the real
trigger: each of assertions 18–21 was run against both the fixed and the
pre-fix definition, and each fails on its own defect rather than passing
vacuously.

## The canonicalisation decision, and why it stopped being urgent

`ADR-0002` settles the highest-consequence item on the artifact's decision list.
The substance of the ADR is not the layout — it is that the layout no longer has
to be right the first time.

`continuum.events.hash_version` records which canonicalisation each row was
written under, and is itself covered by the hash. A future layout is therefore
additive: new events carry version 2, events already written still verify under
version 1, and no chain is invalidated. What made this decision urgent was never
the byte layout, which is an ordinary engineering choice; it was that the choice
appeared to be a one-way door. Versioning removes the door for the cost of one
`smallint`.

Version 1 is the layout the schema already executes and CI already verifies, so
ratifying it changed no hashes.

Two properties were tested rather than asserted:

| Claim | Test |
|---|---|
| The version cannot disagree with the code that computed the hash | Assertion 22 fails with `hash_version has a column default` if the column is given one |
| Flipping the column cannot make a verifier apply the wrong layout | Assertion 22 fails with `events_prepare_hash does not hash hash_version` if the version is dropped from the canonical form |

The ADR also claims that assertion 19 keeps the document and the schema from
drifting apart. That claim was checked directly: with the trigger changed to
stop hashing `hash_version` while the documented recompute still did, assertion
19 failed with `hash is not reproducible`. The check is real, not decorative.

**`SRC-001` stays open.** It covers roughly thirty `[DECISION]` items and this
resolves one. `FND-DB-DOMAIN` stays blocked.

## Fourth round: the RLS hard gate was never actually tested

Applying a PostgreSQL review checklist to the schema surfaced two defects that
share a shape with the candidate's unreachable `digest()` — individually correct
declarations that do not connect, invisible to reading, and found only by
executing as the role that matters.

### The tenant policies were never evaluated

Assertion 5 reads `pg_class.relrowsecurity` and `relforcerowsecurity`. That
proves RLS is *switched on*; it says nothing about what any policy does. And
the verify script runs as `postgres`, a superuser — superusers bypass RLS
entirely, `FORCE` included, so no policy predicate had ever been evaluated.

Demonstrated rather than argued: with the policy replaced by the tautology
`USING (workspace_id = workspace_id)`, which isolates nothing, assertion 5 still
reported *"RLS enabled and forced on all tenant-scoped tables"*. v1.2 states the
hard gate as **zero cross-workspace access**; what was being verified was that a
boolean column was `true`.

Assertion 23 drops to `continuum_app` (`NOLOGIN NOBYPASSRLS`) and tests the gate
itself. Against the tautological policy it fails with `cross-workspace read: 1
row(s) belonging to another tenant are visible`.

Assertion 13 has the same weakness — it greps the policy *text* in `pg_policies`
for `IS NULL`. Assertion 23 now reads an actual built-in agent row as an ordinary
tenant, and fails if that row is invisible.

### The application role could not reach 24 of the 25 tables

`continuum_app` held table privileges on `continuum.events` alone. Row Level
Security constrains *which* rows a role may touch; it does not grant the
privilege to touch any. Every other tenant policy was therefore unreachable —
and a superuser-only test could never notice, because a superuser needs no
grant.

Table privileges are now granted explicitly. The `DELETE` question that PR #8
left open is settled by **ADR-0003**: `continuum_maintenance` holds
`SELECT, DELETE` on the 21 domain tables and `continuum_app` never holds
`DELETE`, so erasure is a separate auditable duty rather than ordinary
application behaviour. Because the maintenance role is `NOBYPASSRLS` like every
other role, a purge runs inside a tenant context and cannot sweep across
workspaces. `events` and `workspaces` are explicitly revoked: the append-only
trigger would reject either, and a grant that cannot be exercised reads as
permission.

Assertion 23 fails with `permission denied for table memories` if the grants are
removed.

### RLS predicates evaluate once per query, not once per row

Each policy calls the helper through a scalar subquery,
`(SELECT continuum.current_workspace_id())`. The function is already `STABLE`,
but a `STABLE` function written directly into a policy qual is still
re-evaluated per row; wrapping it lets the planner hoist it into a one-time
InitPlan. Identical semantics — assertion 23 exercises the wrapped form.

### Verification

Each failure mode was reproduced against the real policy and grant text,
extracted from the schema file rather than retyped:

| Defect introduced | Assertion 23 result |
|---|---|
| Tautological policy | `cross-workspace read: 1 row(s) … visible` |
| Table privileges revoked | `permission denied for table memories` |
| Built-in agents dropped from the read policy | `built-in agents are invisible to a tenant under RLS` |
| None (correct schema) | passes |

## Fifth round: the deletion question was asked at the wrong layer

The fourth round's grants raised an obvious follow-on — if the application must
not delete, which role may? — and the answer taken was `continuum_maintenance`,
on the reasoning that the three-way role split exists to express exactly that.
Automated review then returned six findings on it, two P1, all correct: cascades
from four parents cross the tenant boundary because PostgreSQL applies
referential actions *without* evaluating the child's RLS policy; `NOBYPASSRLS`
bounds each statement, not the session's choice of workspace; `runs` could not
be purged at all; the assertion checked only direct grants; the ADR had not
reached the primary artifact; and maintenance held global `SELECT` on `users`.

Those were fixed. Then the prior question got asked — *is deletion required at
all?* — and the answer changed the design.

### v1.2 specifies a deletion model, and it is not row deletion

| Data class | v1.2 position |
|---|---|
| Domain rows | *"Invalidation is stateful rather than deletion: `durable → invalidated → superseded_by → newer memory`. This preserves historical reasoning."* |
| Artifacts | A retention lifecycle in object storage: `retention_class` (`ephemeral / standard / durable / immutable / legal_hold`) and a nullable `delete_after`. Two classes exist to *prevent* removal. |
| Events | Append-only. Undeletable by construction. |

So hard-deleting a memory or a claim contradicts a stated design principle
rather than merely exceeding least privilege — and the one deletion mechanism
v1.2 does call for operates a layer down and **is not implemented at all**. Two
rounds went into hardening a grant for a capability the specification does not
ask for, while the mechanism it does ask for had no lifecycle job and no
assertion.

### Row deletion would not have achieved erasure anyway

The event store holds `payload jsonb` and cannot be deleted from. If personal
data reaches an event payload, removing the `memories` row leaves the content in
a ledger nothing can touch — the appearance of erasure without the substance.
What may enter `events.payload` is an open `[DECISION]`; v1.2 names the column
and never says. That decision gates every erasure story and is recorded in
ADR-0003 rather than assumed away.

The mechanism that fits this architecture is crypto-shredding: artifacts are
SSE-KMS encrypted under a per-artifact `kms_key_arn`, so destroying the key
renders content unrecoverable while the hash chain stays verifiable. It works
*with* an append-only ledger. The supporting columns are already `[V12]`.

### Outcome

No operational role holds `DELETE`. `continuum_maintenance` returns to schema
`USAGE` only — a privilege granted before a demonstrated need is one nobody has
reasoned about. This also makes the cross-tenant cascade unreachable, since no
role can initiate a cascading delete; that defect is still real and still worth
fixing, but it is no longer load-bearing.

| Configuration | Assertion result |
|---|---|
| `continuum_app` granted `DELETE` | `continuum_app deleted a domain row` |
| `continuum_maintenance` granted `DELETE` | `holds effective DELETE … {continuum_maintenance.claims}` |
| `DELETE` inherited via another role | `holds effective DELETE … {continuum_maintenance.runs}` |
| A sixth `retention_class` added | `retention_class drifted from the v1.2 manifest` |
| `delete_after` made `NOT NULL` | `must be a nullable timestamptz` |
| `retention_class` made nullable | `must be NOT NULL` |
| Correct configuration | passes |

`delete_after` must stay nullable because `legal_hold` and `immutable` are
exactly the classes with no expiry — a `NOT NULL` column would make the two
anti-deletion classes unrepresentable.

### What this round is really a record of

The first four rounds found defects by executing. This one found a defect by
asking whether the requirement existed. Every finding in the maintenance-role
review was correct and worth fixing, and the whole structure being fixed should
not have been built. Checking the specification for a stated position costs one
grep; it was not done until prompted.

## Sixth round: closing the payload, which gates erasure

ADR-0003 deferred the question that gates every erasure story — may personal or
sensitive data enter `events.payload`? v1.2 names the column and never says, but
it does state the rule for a neighbouring sink: raw prompts, raw source bodies,
full personal data, credentials, tokens, keys and private connector payloads are
**prohibited trace attributes**.

The asymmetry decides it. Traces expire; the event chain does not. Content too
sensitive for a sink that ages out does not belong in a permanent, append-only,
hash-chained one.

### Reversible in one direction only

Exclude content now and later need it → start including it going forward, per
event type. Include content now and later need to exclude it → every event ever
written is contaminated, in the one store that cannot be edited, because
`previous_hash` chains each event to the last. Crypto-shredding does not rescue
that case: it works for artifacts because each carries its own `kms_key_arn`,
while `events.payload` is plain `jsonb`.

ADR-0004 therefore fixes payloads as references, enforced three ways rather than
documented once — a policy is not a control when the failure mode is somebody
inlining a user's question at 2am for debugging:

| Mechanism | Property |
|---|---|
| `continuum.event_schemas` | Closed key set per `(event_type, schema_version)` |
| No registered schema → reject | The catalogue is opt-in, not opt-out |
| `continuum.jsonb_8k` on `events.payload` | Bulk content cannot fit at all |

### What it does not buy, stated plainly

It closes the payload *shape*. It **cannot** detect personal data inside a
registered key, and nothing in SQL can — a `note` field can still contain a
name. The guarantee is narrower: the key set is reviewed rather than open, no
field appears at runtime without a registry change, and volume is bounded.
Misuse within an approved field is a review and classification problem.

The production event catalogue is deliberately not seeded. Seeding a permissive
starting set would defeat the fail-closed property immediately; the verification
fixtures register their own types, which is the mechanism demonstrating itself.

### The accepted cost

The event store alone is no longer a complete replay log. Events prove sequence
and integrity; reconstructing content needs the referenced stores. That is a
real reduction in what event sourcing means here, taken deliberately — a log you
can replay in full is a log you cannot erase from.

| Configuration | Assertion result |
|---|---|
| Validation trigger dropped | `an unregistered event_type was accepted` |
| Registry widened to permit `raw_prompt` | `an unregistered payload key was accepted` |
| A catch-all type registered | `an unregistered event_type was accepted` |
| Payload bound loosened to 256 KiB | `a 9000 byte payload was accepted inline` |
| Correct configuration | passes |

The second row is the exact move someone makes when they want the raw input in
the log, and it fails. Assertion 26 also checks that a *well-formed* payload is
accepted — without it, the first two rows would pass equally against a mechanism
that simply rejects everything.

### CI caught the registry escaping the RLS requirement

The first push of ADR-0004 failed: `RLS not enabled/forced on: {event_schemas}`.
Assertion 5 requires RLS on every table under `continuum` except an explicit
exemption list, and a new table had been added without deciding which side of
that line it sits on.

The right answer was the exemption, not a policy: the registry is a global
contract, and a per-tenant event catalogue would let one tenant declare types
the validator applies differently for another. It holds type names and key
names, no tenant data. The exemption is tagged `[DECISION: ADR-0004]` alongside
`users` and `models` rather than added silently.

Worth recording because the assertion did exactly its job — a new table cannot
quietly escape the tenant-isolation requirement, which is the failure mode it
was written for. The fix was verified in both directions: the exemption passes,
and an ordinary unprotected table still fails.

## Seventh round: making the retention schedule executable

ADR-0003 named artifact retention as the one deletion mechanism v1.2 actually
specifies, and noted that none of it was built. ADR-0005 builds it.

v1.2 gives the schedule directly — `ephemeral` 7 days, `standard` 90,
`durable` 365, `immutable` and `legal_hold` policy-defined — and, crucially,
constrains where enforcement may live: **S3 Object Lock is reserved for the
audit bucket**, "only enabled after a specific retention/legal decision". So
Object Lock is not the control holding `immutable` and `legal_hold` artifacts.
The manifest store is, and a schedule living only in a runbook is not
enforcement.

| Mechanism | Property |
|---|---|
| `artifacts_apply_retention` | Derives `delete_after` from `created_at` and the class |
| `artifacts_retention_expiry_consistent` | Held classes carry no expiry; bounded ones must |
| `artifacts_retention_no_weakening` | A class can be strengthened, never lowered |
| `artifacts_due_for_expiry` | Eligibility answered by the schema; a hold cannot appear |
| `content_deleted_at` | The object goes, the manifest row stays |

The ratchet is the load-bearing part. A `legal_hold` artifact cannot be deleted
— but nothing otherwise stops relabelling it `ephemeral` and waiting seven days,
and `continuum_app` holds `UPDATE` on `artifacts`. Without the trigger the holds
are advisory.

### An assertion of mine was decorative, and negative testing caught it

Assertion 28 originally computed its expected expiry dates by calling
`continuum.artifact_retention_days()` — **the function under test**. Both sides
moved together, so the schedule could drift from v1.2 while the assertion passed
happily. Changing `ephemeral` from 7 days to 30 produced no failure.

| Configuration | Result |
|---|---|
| `ephemeral` drifted 7 → 30 days | `the v1.2 retention schedule (7/90/365) was not applied to 1 of 3` |
| `durable` drifted 365 → 400 days | same |
| No-weakening trigger dropped | `a legal_hold artifact was downgraded to ephemeral` |
| Consistency `CHECK` dropped | `a legal_hold artifact was given an expiry` |
| View widened to ignore `content_deleted_at` | `an artifact already expired is still offered` |
| Correct configuration | passes |

The first two rows only exist because the defect was found by running the broken
configuration rather than by reading the assertion. It now compares against the
literal v1.2 dates. This is the same failure mode as `F-02`, in a file whose
governing rule is that a test which cannot fail is a defect — which is why every
assertion here is run against a deliberately broken schema before it is trusted.

### What this does not do

The lifecycle job is not written. Nothing yet reads `artifacts_due_for_expiry`,
deletes the S3 object and sets `content_deleted_at`. ADR-0005 gives that job a
contract it cannot violate; it does not implement it. The audit bucket's Object
Lock decision is untouched, as v1.2 reserves it.

## Eighth round: RLS does not stop a tenant naming another tenant's row

ADR-0003 deferred five single-column foreign keys as "no longer urgent, still a
defect", on the reasoning that the hazard was `ON DELETE CASCADE` crossing the
tenant boundary and that ADR-0003 had left no role holding `DELETE`.

That reasoning was wrong, and the way it was found is the point: the fix was not
started by reading the ADR, it was started by running the unfixed schema.

### The defect was live, not latent

PostgreSQL evaluates referential integrity with row security suspended — its
documented behaviour, so a foreign key cannot be defeated by a policy. The same
property means a tenant that cannot *read* a row can still *reference* it, and
that needs only `INSERT`, which `continuum_app` holds.

Against the schema as it stood, as `continuum_app` with `app.workspace_id` set
to workspace B:

```text
A run visible to B: 0
B failure -> A run:            ACCEPTED
B agent_version -> A agent:    ACCEPTED
```

RLS was working exactly as designed — B could not see A's run — and B referenced
it anyway. The cascade was indeed unreachable; the cross-tenant reference never
needed it.

The same result appears a second time in the negative controls below, where
reverting one FK to its single-column form makes assertion 32 fail with
`continuum_app referenced another workspace's run through the RI bypass`.

### The count was five; it was actually sixteen

ADR-0003 named `agent_versions.agent_id`, `tool_versions.tool_id`,
`evaluation_results.evaluation_id` and `mutation_evaluations.mutation_id` /
`.evaluation_id`. Those are the cascading relationships. Eleven more — mostly
`run_id` on `evidence`, `claims`, `memories`, `failures`, `tool_executions`,
`artifacts`, `cost_events` and `events` — carry the identical defect and had
never been enumerated. All sixteen are now qualified by `workspace_id`.

### A nullable column would have kept the hole open

Nine tables declared `workspace_id` nullable, with `NULL` meaning a built-in
shared by every tenant. Under `MATCH SIMPLE` a `NULL` in any referencing column
skips the composite check **entirely**, so that nullability is not a feature
beside tenant-qualified keys — it is the thing that defeats them. ADR-0006
records why the shared catalogue lost: never `[V12]`, never approved (it was
decision 8), and half-built, since only two of the nine tables ever had the read
policy that would have made a `NULL` row visible to anyone.

### Assertion 35 was rewritten because its own negative control exposed it

The first version ended on a value comparison: after deleting the parent, check
that `workspace_id` survived. Breaking the schema showed that comparison was
unreachable. A bare `ON DELETE SET NULL` does not produce a wrongly-nulled row —
it raises a not-null violation, because the column is `NOT NULL`. The assertion
did fail, but at a statement whose error message says nothing about foreign
keys.

This is the second time in this package that an assertion of mine survived
review and was caught only by deliberately breaking the thing it covered. The
first was assertion 28, which computed its expected dates by calling the
function under test. Neither was found by reading.

### Negative controls

Every new assertion was run against a deliberately broken schema before being
trusted. Local PostgreSQL 16, with the pgvector declarations stripped, since the
review sandbox has neither pgvector nor a Docker daemon; CI runs the unmodified
files on `pgvector/pgvector:0.8.6-pg18-trixie`.

| Mutation | Result |
|---|---|
| *(none — baseline)* | `PASSED` |
| `agent_versions.agent_id` → single-column FK | **31** `cross-workspace parent reference was accepted on a cascading FK` |
| `failures.run_id` → single-column FK | **32** `continuum_app referenced another workspace's run through the RI bypass` |
| `ALTER TABLE ... ADD CONSTRAINT bad_fk FOREIGN KEY (run_id) REFERENCES continuum.runs (id)` | **33** `foreign key(s) not tying the child workspace_id to the parent's: continuum.cost_events.bad_fk -> continuum.runs` |
| `ALTER TABLE continuum.tools ALTER COLUMN workspace_id DROP NOT NULL` | **34** `workspace_id is nullable on: tools` |
| `SET NULL` without its column list | **35** `ON DELETE SET NULL tried to null workspace_id: the constraint is missing its column list` |
| `CASCADE` in place of `SET NULL` | **35** `the child row did not survive its parent; SET NULL behaved as CASCADE` |
| `IS NULL` disjunct restored to a read policy | **13** `policy admits a workspace-less row: agents.agents_read` |

Assertion 34 also caught a defect in itself on first run: written against
`information_schema.columns`, it named `continuum.artifacts_due_for_expiry` as
an offender, because a view's columns are always reported nullable. It reads
`pg_attribute` and filters to `relkind = 'r'`.

Assertion 33 caught one leftover on first run — `memory_embeddings_memory_id_fkey`,
the single-column FK inside the block reproduced verbatim from v1.2. It is
dropped outside that block, so the reproduced text stays unmodified.

### Review round: two findings from Codex, both accepted

**Assertion 33 tested membership, not correspondence.** It asked whether the
parent's `workspace_id` appeared anywhere in the referenced column list. That
accepts a constraint which names it from the wrong child column:

```sql
FOREIGN KEY (id, run_id) REFERENCES continuum.runs (workspace_id, id)
```

Reproduced before fixing. With that constraint in place the assertion reported
no offenders, and `continuum_app` scoped to workspace B successfully inserted a
`cost_events` row referencing workspace A's run — by putting A's workspace UUID
in `id`. The check now walks `confkey` with ordinality and requires the child
column at the same position to be `workspace_id`. Both mutations — the
single-column FK and the swapped-ordinal one — now fail it, and the message was
reworded, since "names its parent by id alone" did not describe the second case.

This is the third assertion of mine in this package to survive my own review and
fail only under a mutation nobody had tried. The pattern is consistent: an
assertion that queries *for the presence of the right thing* tends to pass on
schemas that contain the right thing in the wrong place.

**The companion document still described the pre-fix schema.** `[V12]` and
`[V11]` snippets throughout §3 showed `run_id uuid REFERENCES continuum.runs(id)`
and nullable `workspace_id` columns — the exact shape ADR-0006 removes. Anyone
implementing from the document rather than the SQL would have rebuilt the
vulnerability. Nineteen foreign keys and seven `workspace_id` columns across the
document were corrected, the eight parent snippets gained
`UNIQUE (workspace_id, id)`, and §3 now states plainly that the SQL file is
authoritative and these excerpts are abridged.

The `memory_embeddings` block is deliberately still wrong, and now says so: it
is reproduced verbatim from v1.2, its two independent single-column keys *are*
the defect §5 describes, and the schema closes it outside the block so the
reproduced text stays unmodified.

### What CI must still show

`python scripts/check_sql_syntax.py` accepts `ON DELETE SET NULL (run_id)` under
pglast's PostgreSQL 18 grammar, and applying the schema locally confirms all
seven constraints recorded the column list in `pg_constraint.confdelsetcols`
rather than merely parsing. A green CI check proves the job exited zero; the
`NOTICE` lines from assertions 13 and 31–35 are quoted in the pull request.

## What this package deliberately does not do

It **does not close `SRC-001`**. Issue #2's second close criterion requires
reconstructed detail to be *"approved through an ADR with traceability to
v1.2"*. This package supplies the traceability. The ADRs and the human approval
are separate and outstanding.

It **does not unblock `FND-DB-DOMAIN`**, which stays `blocked` until those
decisions are approved.

The highest-priority decision **was** the event hash canonicalisation (artifact
§4.2); it is resolved by `ADR-0002` and is no longer a one-way door. The
remaining `[DECISION]` items are unaffected and still require ADRs.

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
