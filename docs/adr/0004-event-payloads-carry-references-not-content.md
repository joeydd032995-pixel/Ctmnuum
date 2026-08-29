# ADR-0004: Event payloads carry references, not content

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-08-29
- **Related:** `FND-SPEC-001`; ADR-0002 (hash canonicalisation); ADR-0003 (no deletion)
- **Closes:** deferred item 2 of ADR-0003

## Context

ADR-0003 established that no role deletes a domain row, and deferred the
question that gates every erasure story: **may personal or sensitive data enter
`events.payload`?**

v1.2 names the column and never says what goes in it. It does, however, state
the rule for a neighbouring sink:

> **Prohibited trace attributes:** raw prompts · raw source bodies · full
> personal data · credentials · access tokens · API keys · private connector
> payloads

That governs OpenTelemetry traces. The asymmetry is the whole argument:
**traces expire; the event chain does not.** Content too sensitive for a sink
that ages out has no business in a permanent, append-only, hash-chained one.

## The decision is one-way in exactly one direction

This is the same shape as ADR-0002, and it is why it is being made now rather
than at first write.

| Choice | If it turns out wrong |
|---|---|
| **Exclude content now** | Start including it going forward. Cheap, and reversible per event type. |
| **Include content now** | Every event ever written is permanently contaminated, in the one store that cannot be edited. `previous_hash` chains each event to the last, so removing or redacting one invalidates every subsequent hash. There is no remedy. |

Crypto-shredding does not rescue the second case either. It works for artifacts
because each carries its own `kms_key_arn`; `events.payload` is plain `jsonb` in
PostgreSQL, so shredding would require per-subject field encryption inside the
payload — a design change, not a configuration one.

There is a genuine cost to excluding, and it should be stated plainly: **the
event store alone stops being a complete replay log.** Events prove the sequence
and integrity of what happened; reconstructing *content* requires the referenced
stores. That is a real reduction in what "event sourcing" means here, and it is
accepted deliberately — a log you can replay in full is a log you cannot erase
from.

## Decision

**`events.payload` carries identifiers, status, counters and hashes. Content is
offloaded to an artifact and referenced by `payload_artifact_id`.**

This is enforced structurally, in three parts, because a policy document is not
a control — someone will inline a user's question at 2am for debugging and
nothing will complain.

### 1. A closed key set per event type

`continuum.event_schemas` registers `allowed_keys` for each
`(event_type, schema_version)`. A payload key that is not registered is
rejected. `schema_version` already existed on `events` for exactly this
purpose.

### 2. Fail closed

An `event_type` with no registered schema is rejected outright. The catalogue is
opt-in: a new event type cannot start writing until someone has declared, and
reviewed, what it may carry.

### 3. A hard volume bound

`events.payload` uses `continuum.jsonb_8k` rather than the general
`jsonb_256k`. 8 KiB comfortably holds identifiers, a status, counters and a
hash; it does not hold a document or a transcript. Without this, a registered
key becomes a smuggling channel.

**The production event catalogue is deliberately not seeded.** Naming the real
event types is a larger decision than this ADR, and seeding a permissive
starting set would defeat the fail-closed property on day one. The registry
ships empty; the verification fixtures register their own types, which is the
mechanism demonstrating itself.

## What this does and does not buy

It **closes the payload shape**. The set of keys any event may carry is
declared, reviewed, bounded and testable, and no new field can appear at
runtime without a registry change.

It **does not detect personal data semantically**, and nothing in SQL can. A
registered key can still be filled with something it should not hold — a
`note` field can contain a name. What the mechanism guarantees is narrower and
worth stating precisely: the key set is reviewed rather than open, and bulk
content cannot fit at all. Catching misuse *within* an approved field is a code
review and data-classification problem, not a schema one.

## Consequences

**Positive.** Erasure becomes possible without touching the chain: erase the
referenced artifact or row, and the event survives with its hash still valid,
truthfully recording that something happened while the content is gone. The
sensitive tier concentrates in object storage, where `retention_class`, Object
Lock and per-artifact KMS keys already apply. The database's classification
stops being set by whatever the noisiest producer decided to log — which also
means backups, replicas and CI fixtures stop inheriting it.

**Negative.** Replay from the log alone is lossy. Debugging needs the referenced
stores intact. Every new event type costs a registry entry and a review — the
friction is the point, but it is friction.

**Deferred.** The production event catalogue: which types exist and what each
may carry. This ADR provides the mechanism and deliberately leaves the contents
empty.

## Verification

`docs/spec/continuum_v1.2_core_schema.derived.verify.sql`, applied to
PostgreSQL 18 + pgvector in CI:

- **26** — an unregistered `event_type` is rejected; a registered type carrying
  an unregistered key is rejected; a registered type carrying only registered
  keys is **accepted**. The third is not decoration: without it the first two
  would pass equally well against a mechanism that rejects everything.
- **27** — a 9 KB payload is rejected, and `events.payload` is confirmed to
  carry the tightened domain rather than the general one.

Each was run against both the correct and the defective configuration:

| Configuration | Result |
|---|---|
| Validation trigger dropped | `an unregistered event_type was accepted` |
| Registry widened to permit `raw_prompt` | `an unregistered payload key was accepted` |
| A catch-all type registered | `an unregistered event_type was accepted` |
| Payload bound loosened to 256 KiB | `a 9000 byte payload was accepted inline` |
| Correct configuration | passes |

The second row is the one that matters: it is the exact move someone makes when
they want the raw input in the log, and it fails.

## Rollback

`git revert`. No persistent database holds Continuum events, so no migration is
implied. Reverting restores an unbounded, unregistered payload — which is the
state this ADR exists to leave.

## Provenance

The prohibited-content list is `[V12]`, stated for trace attributes. Extending
it to `events.payload`, the registry, the fail-closed behaviour and the 8 KiB
bound are all `[DECISION: ADR-0004]` — v1.2 does not state them. Nothing here
may be cited as recovered v1.2 specification text — `CONT-LOCAL-GOV-001`.
