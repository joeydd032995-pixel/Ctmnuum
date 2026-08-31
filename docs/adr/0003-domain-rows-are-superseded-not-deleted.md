# ADR-0003: Domain rows are superseded, not deleted

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-08-28
- **Related:** `FND-SPEC-001`; ADR-0001 (role split); PR #8
- **Supersedes:** the `[DECISION]` comment introduced with the table grants in PR #8

## Context

PR #8 granted `continuum_app` the table privileges its RLS policies need —
before that it could not reach 24 of the 25 tables, so every tenant policy was
unreachable. It withheld `DELETE` from every role, marked `[DECISION]`, pending
this ADR.

The obvious next step looked like assigning deletion to a role: the application
should not hard-delete, so give the duty to `continuum_maintenance`, which is
what the three-way role split exists to express. That was the shape of the first
draft of this ADR, and it was wrong — not in its reasoning about roles, but in
never asking whether deletion was specified at all.

**It is.** v1.2 states a deletion model, and it is not row deletion.

## What v1.2 actually says

**Domain rows are invalidated, not removed.**

> Invalidation is stateful rather than deletion:
> `durable → invalidated → superseded_by → newer memory`
> This preserves historical reasoning.

That is a stated design principle, not a silence to be filled. Hard-deleting a
memory or a claim contradicts it. The schema already carries the mechanism:
`invalidated_at`, `status`, and `superseded_by` on both `memories` and `claims`.

**Artifacts have a retention lifecycle, one layer down.** The artifact manifest
fixes `retention_class` — `ephemeral | standard | durable | immutable |
legal_hold` — and a nullable `delete_after`. Bulk content lives in object
storage under SSE-KMS with a per-artifact `kms_key_arn`; the row is a manifest
and a pointer. Removal there is an object-store lifecycle action, not a SQL
`DELETE`. Two of the five classes exist specifically to **prevent** removal, and
v1.2 additionally reserves S3 Object Lock for the audit bucket behind an
explicit retention decision.

**The event store is append-only.** Undeletable by construction.

Three data classes, three different answers, and none of them is "grant `DELETE`
on domain tables."

## Decision

**No operational role holds `DELETE` on any domain table.**

`continuum_app` holds `SELECT, INSERT, UPDATE` and never `DELETE`.
`continuum_maintenance` holds no table privileges at all. There is no
demonstrated need for one, and a privilege granted before a need is a privilege
nobody has reasoned about.

Deletion, where v1.2 calls for it, is artifact retention acting on object
storage. That lifecycle is **not implemented** and this ADR does not implement
it; it records the contract the future work acts on, and asserts that contract
has not drifted.

## Why not simply assign deletion to the maintenance role

Because row deletion would not achieve what it appears to.

The event store holds `payload jsonb` and cannot be deleted from. If personal or
sensitive data reaches an event payload, deleting the corresponding `memories`
row leaves that content in a ledger nothing can remove — the *appearance* of
erasure without the substance, which is worse than not offering it. **What may
enter `events.payload` is itself an open `[DECISION]`**: v1.2 names the column
and never says. That decision, not the grants, determines whether erasure is
possible at all, and it should be made before any erasure path is built.

The coherent mechanism for this architecture, when erasure is required, is
**crypto-shredding**: artifacts are encrypted under a per-artifact
`kms_key_arn`, so destroying the key renders content unrecoverable while the
hash chain stays intact and verifiable. It is a recognised erasure approach, and
unlike row deletion it works *with* an append-only ledger rather than against
it. The columns that support it are already in the schema as `[V12]`. Adopting
it is a separate decision and is not made here.

## Consequences

**Positive.** The privilege model matches the specified lifecycle instead of a
capability nobody asked for. A compromised application session cannot destroy
history. The cross-tenant cascade hazard found in review — four parents whose
children reference them by `id` alone, where PostgreSQL applies referential
actions *without* evaluating the child's RLS policy — becomes unreachable, since
no role can initiate a cascading delete. That defect still exists and should be
fixed on its own merits, but it is no longer load-bearing.

**Negative.** There is no erasure path today. If a legal erasure obligation
arrives before the retention lifecycle and the payload decision are settled, it
will be discharged by a privileged migration under human control — which is
slow and manual, and is the honest position rather than a role that looks like
an answer.

**Deferred, deliberately.**

1. ~~**Artifact retention enforcement**~~ — **RESOLVED by ADR-0005.** The
   7/90/365 schedule is applied by the store, held classes carry no expiry and
   cannot be downgraded, and the eligibility view structurally cannot offer a
   hold to a deletion job. The lifecycle job itself remains unwritten.
2. ~~**Event payload policy**~~ — **RESOLVED by ADR-0004.** Payloads carry
   references, not content: a closed key set per event type, fail-closed
   registration, and an 8 KiB bound. Erasure is now possible without touching
   the chain — erase the referent, and the event survives with its hash valid.
3. **Erasure mechanism** — crypto-shredding versus another approach, once (2) is
   settled.
4. **Workspace teardown** — deleting a tenant cascades into the append-only
   event store, so it cannot work by cascade regardless of privileges. Needs its
   own retention decision.
5. ~~**Composite foreign keys**~~ — **RESOLVED by ADR-0006.** All sixteen —
   not the five named here — now name their parent by `(workspace_id, id)`.
   The entry above called this "no longer urgent" on the grounds that nothing
   can delete. That was wrong about the defect: the cascade was unreachable,
   but creating the cross-tenant *reference* never required `DELETE`, and
   `continuum_app` could do it. Reproduced before the fix, as `continuum_app`
   scoped to workspace B: A's run invisible (0 rows), and referenced anyway.

## Verification

`docs/spec/continuum_v1.2_core_schema.derived.verify.sql`, applied to
PostgreSQL 18 + pgvector in CI:

- **24** — `continuum_app` is refused a `DELETE` behaviourally, and neither
  operational role holds *effective* `DELETE` on any of the 25 tables.
  `has_table_privilege`, not `role_table_grants`, so a privilege inherited from
  another role or granted to `PUBLIC` is caught.
- **25** — the artifact retention contract is intact: exactly the five v1.2
  classes, a nullable `delete_after`, and a `NOT NULL` `retention_class`.

Each was run against both the correct and the defective configuration:

| Configuration | Result |
|---|---|
| `continuum_app` granted `DELETE` | `continuum_app deleted a domain row` |
| `continuum_maintenance` granted `DELETE` | `holds effective DELETE … {continuum_maintenance.claims}` |
| `DELETE` inherited via another role | `holds effective DELETE … {continuum_maintenance.runs}` |
| A sixth `retention_class` added | `retention_class drifted from the v1.2 manifest` |
| `delete_after` made `NOT NULL` | `must be a nullable timestamptz` |
| `retention_class` made nullable | `must be NOT NULL` |
| Correct configuration | passes |

`delete_after` must stay nullable for a reason worth stating: `legal_hold` and
`immutable` are precisely the classes that have no expiry, so a `NOT NULL`
column would make the two anti-deletion classes unrepresentable.

## Rollback

`git revert`. No persistent database holds Continuum data.

## Provenance

The lifecycle is `[V12]` — invalidation and supersession are stated directly, as
is the artifact retention manifest. The *enforcement* of "no role holds
`DELETE`" is `[DECISION: ADR-0003]`: v1.2 states the model, not the privilege
grants that hold it. Nothing here may be cited as recovered v1.2 specification
text — `CONT-LOCAL-GOV-001`.
