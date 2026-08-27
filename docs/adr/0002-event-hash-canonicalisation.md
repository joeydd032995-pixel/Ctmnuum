# ADR-0002: Event hash canonicalisation, and versioning it so the choice is reversible

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-08-25
- **Related:** GitHub issue #2; `SRC-001`; work package `FND-SPEC-001`
- **Supersedes:** the `[DECISION]` marker on §4.2 of
  `docs/spec/Continuum_v1.2_Core_Implementation_Artifact.derived.md`

## Context

Continuum v1.2 states that the `previous_hash` / `event_hash` chain on
`continuum.events` "allows Continuum to detect silent modification of audit
history", and requires a `continuum_event_hash_failures_total` metric. It does
not state the canonicalisation — the exact bytes that are hashed.

The machine-readable core artifact that would have contained it is
unrecoverable (see `FND-SPEC-001`), so the layout had to be reconstructed. That
made it the single highest-consequence open decision in the artifact's
traceability list, for one reason: **the choice appeared to be a one-way door.**
Once the first event is written, changing the layout invalidates every existing
chain, because every later `previous_hash` depends on every earlier
`event_hash`. A schema that pins the layout implicitly forces the decision to be
made perfectly, before any operational experience, under threat of a migration
that cannot be performed.

That framing was the actual problem. The layout itself is a normal engineering
choice; its irreversibility was what made it urgent.

## Decision

Two parts, and the second is the load-bearing one.

### 1. Version the layout per row

`continuum.events` carries `hash_version smallint NOT NULL`, written by
`continuum.events_prepare_hash()` and **included in the hashed canonical form**.

- It is never given a column default. The value is written by the same function
  that computes the hash beside it, so the two cannot disagree — the same
  reasoning that moved `sequence` allocation into the trigger.
- It is covered by the hash. Otherwise an attacker could flip the column and
  induce a verifier to apply the wrong layout to a row, which would either
  produce a false mismatch or, worse, let a forged row validate.

A verifier reads `hash_version` and applies the layout that version defines. A
future layout is therefore **additive**: events written from that point carry
version 2, events already written still verify under version 1, and no chain is
invalidated. The door swings both ways for the cost of one `smallint`.

### 2. Version 1 is the layout the schema executes today

```
canonical = jsonb_build_object(
    'hash_version',        hash_version,      -- 1
    'sequence',            sequence,
    'event_id',            event_id,
    'workspace_id',        workspace_id,
    'run_id',              run_id,
    'event_type',          event_type,
    'schema_version',      schema_version,
    'aggregate_type',      aggregate_type,
    'aggregate_id',        aggregate_id,
    'causation_event_id',  causation_event_id,
    'correlation_id',      correlation_id,
    'actor_type',          actor_type,
    'actor_id',            actor_id,
    'trace_id',            trace_id,
    'payload',             payload,
    'payload_artifact_id', payload_artifact_id,
    'previous_hash',       previous_hash,
    'occurred_at',         to_char(occurred_at AT TIME ZONE 'UTC',
                                   'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
)

event_hash = encode(sha256(convert_to(canonical::text, 'UTF8')), 'hex')
```

`previous_hash` is the `event_hash` of the preceding event in the same
`workspace_id` chain ordered by `sequence`, and SQL `NULL` for the genesis
event.

Each property below is here because its absence was a defect found by review or
by execution, not because it was chosen a priori:

| Property | Why |
|---|---|
| `jsonb`, not delimiter concatenation | `jsonb` normalises key order and whitespace on storage, so `canonical::text` is a deterministic function of the values. A separator-byte concatenation is unambiguous only if no field can contain that byte — `payload` can. |
| `occurred_at` as explicit UTC text | Passing the `timestamptz` directly serialises it through the *writing session's* `TimeZone`. Two writers with different settings hash the same instant differently, and no verifier can reproduce either hash from the stored row. |
| `payload_artifact_id` included | Past 256 KiB the payload is offloaded and this UUID is the only link to the content. Omitting it lets the reference be repointed with `event_hash` and every later link still valid — precisely the silent modification the chain exists to detect. |
| `sequence` included | Binds each event to its position, so the chain detects reordering and not only edits. |
| `hash_version` included | See above. |
| Computed server-side | No caller can write an event whose hash disagrees with its own contents. |
| Builtin `sha256(bytea)`, not `pgcrypto`'s `digest()` | The function is `SECURITY DEFINER` with a hardened `search_path` that excludes `public`, where `pgcrypto` installs `digest()`. The two are mutually exclusive; the builtin lives in `pg_catalog`, needs no extension, and keeps the hardening intact. |

## Provenance

The canonicalisation is `[DERIVED]` and this ADR does not change that. v1.2
states the chain's *purpose* and its failure metric; it never states the byte
layout. Nothing here may be cited as recovered v1.2 specification text —
`CONT-LOCAL-GOV-001`.

The `hash_version` column is `[DECISION: ADR-0002]`: v1.2 does not name it, and
it exists to serve this ADR.

## Consequences

**Positive.** The highest-consequence decision in the traceability list stops
being urgent. The layout can be revised once there is operational experience —
a different digest, a different field set, an external canonicalisation — without
a migration that cannot be performed. Verifiers gain an explicit contract to
switch on rather than an implicit assumption about when a row was written.

**Negative.** Every verifier must switch on `hash_version` rather than assuming
one layout, and each retired version's rules must be kept for as long as events
written under it are retained. This is the ordinary cost of a versioned format
and is much smaller than the cost it removes.

**Not addressed.** This ADR fixes the layout and its versioning. It does not
make the hash reproducible outside PostgreSQL: version 1 depends on
PostgreSQL's `jsonb` text rendering, so a verifier in another language must
replicate that rendering rather than a published standard. If cross-language
verification becomes a requirement, that is the natural motivation for a
version 2 built on RFC 8785 (JCS) — which is now a routine change rather than
an impossible one.

## Verification

`docs/spec/continuum_v1.2_core_schema.derived.verify.sql`, applied to
PostgreSQL 18 + pgvector in CI:

- **16** — the chain is computed server-side and follows `sequence` order,
  including for events written in one transaction.
- **17** — a forged `previous_hash` is rejected rather than silently overwritten.
- **19** — the stored hash is reproducible by an independent re-implementation
  of the layout above, run under a non-UTC session `TimeZone`. This is also the
  mechanical check that this ADR and the executing schema cannot drift apart.
- **20** — `payload_artifact_id` is covered by the hash.
- **21** — the ordering value is allocated under the chain lock, and the
  chain-head lookup is indexed.
- **22** — `hash_version` has no column default, is present on every event, and
  is itself hashed.

Plus `scripts/verify_event_chain_concurrency.sh`, which writes concurrently
from several sessions into one workspace and asserts the chain is intact in
`sequence` order.

## Rollback

Revert the commit. No persistent database holds Continuum events yet, so there
is no data to migrate. This is the last point at which that is true, which is
why the decision is being recorded now rather than at first write.

## What this does not close

`SRC-001` remains **open**. It covers roughly thirty `[DECISION]` items; this
ADR resolves one of them — the highest-consequence one. `FND-DB-DOMAIN` remains
**blocked**.
