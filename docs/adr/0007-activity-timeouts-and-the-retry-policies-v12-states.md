# ADR-0007: Activity timeouts, and the retry policies v1.2 states

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-09-01
- **Related:** `FND-SPEC-002`; ADR-0001 (bootstrap boundary); finding F-07
- **Closes:** `[DECISION]` 5 of the companion document; F-07

## Context

§7.2 is the one item v1.2 explicitly delegates and never restates:

> Activity timeouts are defined in the downloadable core artifact.

That artifact is `SRC-001` — unrecoverable. So every timeout value is a
`[DECISION]` with no source to appeal to, and this ADR is what authorises the
values already in `services/orchestrator/temporal/policies.py` rather than
leaving them in-tree unapproved.

Alongside them sits a *different* problem that looks similar and is not.
**F-07: v1.2 does state four retry policies, in full, and none of their interval
fields were encoded anywhere.** `ActivityPolicy` carried `maximum_attempts` and
the two timeouts; `initial_interval`, `backoff_coefficient` and
`maximum_interval` were specified and simply absent. Temporal applied its own
defaults instead.

Those are opposite failures — one has no source, the other had a source nobody
implemented — and conflating them is exactly what `CONT-LOCAL-GOV-001` forbids.

## Decision

### 1. The timeouts are ratified as `[DECISION: ADR-0007]`

| Class | start_to_close | schedule_to_close | heartbeat |
|---|---:|---:|---:|
| `model_call` | 120 s | 300 s | — |
| `retrieval` | 60 s | 180 s | — |
| `tool_call` | 120 s | 300 s | — |
| `long_running` | 3600 s | 7200 s | 30 s |

These are the values already in-tree. The ADR records existing choices; it does
not introduce new ones. `ActivityPolicy.__post_init__` now rejects a
`schedule_to_close` below `start_to_close`, which no single attempt could fit
inside.

### 2. The four retry policies are reproduced as `[V12]`

```python
RETRY_POLICIES = {
    "MODEL_RETRY":       initial 2 s, backoff 2.0, max 20 s, 3 attempts,
    "IO_RETRY":          initial 1 s, backoff 2.0, max 30 s, 5 attempts,
    "SIDE_EFFECT_RETRY": initial 2 s, backoff 2.0, max 30 s, 3 attempts,
    "SANDBOX_RETRY":     initial 5 s, backoff 2.0, max 30 s, 2 attempts,
}
```

Recovered specification text, not reconstruction. `MODEL_RETRY` and
`SIDE_EFFECT_RETRY` also name non-retryable error types; `IO_RETRY` and
`SANDBOX_RETRY` name none, and an entry appearing on either would be an addition
to the specification rather than a reproduction of it.

`runtime.py` now passes the interval fields into the SDK `RetryPolicy`. Encoding
them without applying them would answer F-07's wording and not its substance.

### 3. The class-to-policy mapping is `[DERIVED]`, and it changes behaviour

v1.2 states the four policies and states the activity classes. **It never says
which governs which.** The mapping is therefore inferred:

| Class | Policy | Why |
|---|---|---|
| `model_call` | `MODEL_RETRY` | named for it; its non-retryable list is provider and budget errors |
| `retrieval` | `IO_RETRY` | read-only I/O, the only class with no side effect to be idempotent about |
| `tool_call` | `SIDE_EFFECT_RETRY` | the side-effecting class; its list names `HumanApprovalRejected` and `NonIdempotentActionError`, which only apply here |
| `long_running` | `SANDBOX_RETRY` | the sandboxed class, and the only one that heartbeats |

**This is the consequential part.** The classes previously carried their own
`maximum_attempts`, and two disagreed with the policy now mapped to them:

| Class | was | now | source |
|---|---:|---:|---|
| `retrieval` | 3 | **5** | `IO_RETRY` |
| `tool_call` | 2 | **3** | `SIDE_EFFECT_RETRY` |

`maximum_attempts` is now a property reading through to the mapped policy, so
there is one source for the number rather than two that can drift. Where the
in-tree value disagreed with v1.2, v1.2 wins.

The residual risk is stated plainly: **if the mapping is wrong, the attempt
counts are wrong.** It is `[DERIVED]`, not `[V12]`, and it is asserted by a test
so that changing it is a deliberate act rather than a quiet one.

### 4. Non-retryable error types are the union, not a replacement

v1.2's per-policy list plus Continuum's `PERMANENT_ACTIVITY_ERROR_TYPES`. The
`continuum.*` types are this implementation's own and are permanent regardless
of which policy applies; v1.2's are drawn from its error taxonomy. Dropping
either set would make some terminal error retry.

## Consequences

- Retrieval retries up to 5 times and tool calls up to 3, where they previously
  stopped at 3 and 2. On a genuinely failing dependency this is more attempts
  and more elapsed time before the activity gives up — bounded by
  `schedule_to_close`, which is unchanged.
- `maximum_attempts` is no longer a constructor argument on `ActivityPolicy`.
- F-07 is closed: the values are encoded *and* applied.
- **F-06 is not closed and is larger than its description** — see the evidence
  file. It is tracked as its own issue rather than folded in here.

## Verification

`tests/temporal/test_temporal_foundation.py`, asserted against **literal**
values rather than read from `RETRY_POLICIES`: a test that takes its expectation
from the thing under test cannot fail, which this package has produced before.
These need no Temporal server, so they run in the review sandbox.

| Mutation | Caught by |
|---|---|
| `MODEL_RETRY` maximum_interval 20 → 25 | `policy='MODEL_RETRY'`, `25 != 20` |
| `IO_RETRY` attempts 5 → 3 | `activity_class='retrieval'`, `3 != 5` |
| `tool_call` remapped to `IO_RETRY` | `activity_class='tool_call'`, `'IO_RETRY' != 'SIDE_EFFECT_RETRY'` |
| `MODEL_RETRY` backoff 2.0 → 1.0 | `policy='MODEL_RETRY'`, `1.0 != 2.0` |
| A spurious error type on `IO_RETRY` | `Tuples differ: ('Spurious',) != ()` |

## Provenance

Retry policy values: `[V12]`. Timeouts: `[DECISION: ADR-0007]`. Class-to-policy
mapping and the error-type union: `[DERIVED]`. Nothing here may be cited as
recovered v1.2 specification text except the retry values.
