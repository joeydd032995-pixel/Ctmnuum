# ADR-0005: Artifact retention is enforced by the store

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-08-29
- **Related:** `FND-SPEC-001`; ADR-0003 (no deletion of domain rows); ADR-0004 (payloads carry references)
- **Closes:** deferred item 1 of ADR-0003

## Context

ADR-0003 established that no role deletes a domain row, and identified artifact
retention as the one deletion mechanism v1.2 actually specifies — then noted
that none of it was built.

v1.2 states the schedule directly:

```text
ephemeral    7 days
standard    90 days
durable    365 days
immutable   policy-defined
legal_hold  policy-defined
```

It also constrains where the enforcement can live:

> Object Lock is reserved for the audit bucket and only enabled after a specific
> retention/legal decision because enabling Object Lock has operational
> consequences and cannot simply be treated as an ordinary reversible
> configuration change.

That rules out the obvious answer. **S3 Object Lock is not the control holding
`immutable` and `legal_hold` artifacts** — it is reserved for the audit bucket
behind its own decision. The manifest store is therefore where retention has to
be enforced, and a schedule that lives only in a runbook is not enforcement.

## Decision

**The store applies the schedule, refuses to weaken it, and answers the
eligibility question itself.**

### 1. The schedule is applied, not remembered

`continuum.artifact_retention_days()` encodes the v1.2 numbers.
`artifacts_apply_retention` fills `delete_after` from `created_at` plus that
interval when the caller does not supply one. A caller may still choose an
earlier or later date for a bounded class; what it may not do is give a held
class an expiry.

### 2. Held classes carry no timer

`artifacts_retention_expiry_consistent` requires that `immutable` and
`legal_hold` have `delete_after IS NULL`, and that the three bounded classes
have one. It is written as an explicit `CASE`, not a boolean expression over
`NULL`s:

```sql
CASE WHEN retention_class IN ('immutable','legal_hold')
     THEN delete_after IS NULL
     ELSE delete_after IS NOT NULL END
```

`delete_after IS NULL` inside an `OR` would let a `NULL` make the whole `CHECK`
evaluate to `NULL`, and `CHECK` rejects only `FALSE`. That exact three-valued
trap has already been a defect in this schema once.

### 3. Retention is a ratchet

`artifacts_retention_no_weakening` refuses any `UPDATE` that lowers the class.
**This is the attack the schedule invites**: an artifact under `legal_hold`
cannot be deleted, but nothing otherwise stops a caller relabelling it
`ephemeral` and waiting seven days. `continuum_app` holds `UPDATE` on
`artifacts`, so without this the holds are advisory.

The comparison relies on the declared order of `continuum.retention_class`.
That is safe because assertion 25 already pins the enum to exactly the v1.2
list, so a reordering that would silently invert the check fails there first.

Lifting a hold is deliberately **not** expressible through the application. It
requires the table owner — a migration — which is the auditable path, matching
ADR-0003's posture that irreversible acts are separate from ordinary behaviour.

### 4. Eligibility is a schema question, not a job question

`continuum.artifacts_due_for_expiry` returns what may be removed now. A held
artifact cannot appear in it: the predicate requires a `delete_after`, and held
classes have none. **A carelessly written lifecycle job still cannot reach a
hold**, because the schema will not offer it one.

### 5. The object goes; the row stays

`content_deleted_at` records that the object was expired from storage while the
manifest row remains. Retaining the row follows ADR-0003 — a row pointing at
removed content still truthfully records that the artifact existed and when its
content went — and it is also what stops a lifecycle job selecting the same
artifact forever.

`content_deleted_at` is **store-side only**. The v1.2 artifact manifest sets
`additionalProperties: false`, so it cannot be a manifest field; this is a
column on the derived table and is tagged accordingly.

## Consequences

**Positive.** The schedule is executable rather than documentary. Holds are
structural: the two classes that exist to prevent removal cannot be given an
expiry, cannot be downgraded by the application, and cannot be handed to a
deletion job. Erasure of artifact content becomes possible without touching any
chain, which is what ADR-0003 and ADR-0004 were building toward.

**Negative.** Lifting a legal hold now requires a migration. That is friction by
design, but it is friction: an operator who needs a hold released cannot do it
through the application.

**Not addressed.** The lifecycle job itself — whatever reads
`artifacts_due_for_expiry`, deletes the S3 object and sets `content_deleted_at`
— is not written here. This ADR gives it a contract it cannot violate; it does
not implement it. Nor does it touch the audit bucket's Object Lock decision,
which v1.2 explicitly reserves.

## Verification

`docs/spec/continuum_v1.2_core_schema.derived.verify.sql`:

- **28** — the 7/90/365 schedule is applied to the bounded classes; a held class
  cannot be given an expiry; a bounded class cannot escape having one.
- **29** — a `legal_hold` artifact cannot be downgraded to `ephemeral`;
  strengthening still works.
- **30** — an expired artifact is offered; held and unexpired ones never are;
  one already recorded as removed drops out.

Each was run against both the correct and the defective configuration:

| Configuration | Result |
|---|---|
| `ephemeral` schedule drifted 7 → 30 days | `the v1.2 retention schedule (7/90/365) was not applied to 1 of 3` |
| `durable` drifted 365 → 400 days | same |
| No-weakening trigger dropped | `a legal_hold artifact was downgraded to ephemeral` |
| Consistency `CHECK` dropped | `a legal_hold artifact was given an expiry` |
| View widened to ignore `content_deleted_at` | `an artifact already expired is still offered` |
| Correct configuration | passes |

**The first two rows are the point of this section.** The schedule check
originally computed its expected dates by calling
`artifact_retention_days()` — the function under test — so both sides moved
together and the schedule could drift from v1.2 freely while the assertion
passed. It was caught by running the defective configuration, not by reading.
The assertion now compares against the literal v1.2 dates.

## Rollback

`git revert`. No persistent database holds Continuum artifacts, so no migration
is implied.

## Provenance

The schedule (7/90/365, `immutable` and `legal_hold` policy-defined) and the
Object Lock reservation are `[V12]`, stated directly. The `NULL`-expiry rule for
held classes, the no-weakening ratchet, the eligibility view and
`content_deleted_at` are `[DECISION: ADR-0005]` — v1.2 states the schedule, not
the mechanism that holds it. Nothing here may be cited as recovered v1.2
specification text — `CONT-LOCAL-GOV-001`.
