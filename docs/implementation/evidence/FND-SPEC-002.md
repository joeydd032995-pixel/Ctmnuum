# Evidence — FND-SPEC-002

## Scope

Work package: `FND-SPEC-002` — ADR approval of the derived reconstruction,
closing `SRC-001`.

`FND-SPEC-001` delivered a derived replacement for the unrecoverable v1.2 core
artifact and proved it executable. It did not make it *approved*. Issue #2's
second close criterion requires that, and until this package the closure work
had no work package, no gates and no evidence file — a high-severity gap
blocking a high-risk package, with nothing able to confirm progress toward
closing it. The verifier could confirm the gap's `blocks` reference was not
dangling and no more. That is the same omission `FND-CTRL-002` was created to
fix, one level up.

## What issue #2 requires, clause by clause

> Close when either: 1. the original machine-readable artifact is recovered and
> committed under `docs/spec/`, or 2. **every missing field/version/timeout has
> been reconstructed from authoritative source material and approved through an
> ADR with traceability to v1.2.**

Criterion 1 is unreachable — `FND-SPEC-001` established the original is not in
the corpus and treated it as unrecoverable. Criterion 2, answered per clause:

| Clause | Answered by | Claim |
|---|---|---|
| **field** | ADR-0009 (`users`/`models` RLS exemption), ADR-0010 (the 31 residual declarations), plus ADR-0002 through ADR-0006 already accepted | Complete. Every `[DECISION]` tag maps to an accepted ADR, checked mechanically. |
| **timeout** | ADR-0007 | Complete. The four activity classes' timeouts are ratified; the four v1.2 retry policies are encoded *and applied*. |
| **version** | ADR-0008 | **Narrower than the literal wording — see below.** |

### The version clause is answered narrowly, and deliberately

ADR-0008 does not pin the six libraries §6.2 names. None is imported anywhere in
the tree, and §6.2 itself forbids the alternative:

> Inventing version numbers here would be exactly the failure
> `CONT-LOCAL-GOV-001` prohibits. These must be pinned at implementation time
> and recorded in `uv.lock`, not asserted as recovered specification.

So ADR-0008 approves the **rule** — lockfiles are authoritative, each library is
pinned by the package that first imports it, no version is ever presented as
v1.2 text — and records what is pinned today.

**This is a weaker claim than "every version is decided", and `SRC-001` is
closed on the weaker one.** A reviewer who reads issue #2 as requiring literal
values for all six now should reopen the gap; the choice between readings was
made rather than elided, and it is recorded in ADR-0008's own consequences
section as well as here.

## Findings

### F-07 was a specified value nobody implemented

`ActivityPolicy` carried `maximum_attempts` and two timeouts. v1.2 states four
retry policies **in full** — `initial_interval`, `backoff_coefficient`,
`maximum_interval` — and none of those three fields existed anywhere in the
tree. Temporal applied its own defaults instead.

That is the opposite of the timeout problem: the timeouts have no source, the
retry intervals had a source nobody read. Conflating them is what
`CONT-LOCAL-GOV-001` exists to prevent, so ADR-0007 tags them separately —
retry values `[V12]`, timeouts `[DECISION]`.

The intervals are now passed into the SDK `RetryPolicy` in `runtime.py`.
Encoding them as constants without applying them would have answered F-07's
wording and not its substance.

### The class-to-policy mapping is derived, and it changed behaviour

v1.2 states the four policies and states the four activity classes. It never
says which governs which. The mapping is `[DERIVED]`, and two classes carried
attempt counts that disagreed with the policy now mapped to them:

| Class | was | now | source |
|---|---:|---:|---|
| `retrieval` | 3 | 5 | `IO_RETRY` |
| `tool_call` | 2 | 3 | `SIDE_EFFECT_RETRY` |

`maximum_attempts` reads through to the mapped policy, so there is one source
for the number instead of two that drift. One existing test asserted the old
`model_call` non-retryable list and failed on this change — correctly, since the
list is now the union of v1.2's and Continuum's. It was updated deliberately
rather than relaxed.

### F-06 is much larger than its one-line description

Recorded here because it was measured while working on F-07, and because the
divergence paragraph understates it. It is **not** fixed by this package.

| | v1.2 | in-tree |
|---|---|---|
| task queues | `control`, `interactive`, `batch`, `actions`, `sandbox`, `gpu` | `foundation`, `interactive`, `standard`, `background`, `evaluation`, `mutation`, `sandbox` |
| overlap | only `interactive` and `sandbox` match | 2 of 6 |
| priority scale | 1–5, **1 is highest** | 10–80, **80 is highest** |

Four of six v1.2 queues are absent, five in-tree queues are invented, and the
priority scale is **inverted** as well as differently keyed. Tracked as its own
issue rather than folded in here.

## Two methodological failures worth recording

### Stale bytecode silently invalidated a negative control

The controls mutate a source file, re-run a test and expect failure. Restoring
`policies.py` and re-running reported the mutated result: Python served a cached
`__pycache__/*.pyc`. Under PEP 420 namespace packages with rapid rewrites, the
mtime granularity let a stale cache win.

**A negative control that mutates source is only trustworthy with the bytecode
cache cleared.** Every control below was re-run with `__pycache__` removed and
`python -B`. The first pass's results were discarded rather than reported.

This matters beyond this package: it is a way for "I broke it and watched it
fail" to produce a false result, which is the discipline this repository relies
on most.

### The new check was wrong on its first run, and the schema was right

`check_decision_coverage.py` reported the companion enumeration listing 31
declarations against 33 tags in the schema. The tempting fix is to edit the
document. The correct one was that two of the 33 are not declarations — the
provenance legend at the top of the file, and a prose comment about grants.

The check now counts only lines with SQL before the comment marker. **A check
that reports drift is not automatically right about which side drifted.**

Its "referenced ADR is not Accepted" branch was also decorative at first: it
scanned only `docs/spec/`, and ADR-0007's tags live in `policies.py`. Setting
that ADR to `Proposed` produced no error. The scan now covers every file that
carries a tag, and the branch fires from both a Python and a SQL source.

## Negative controls

Retry policies and mapping — `tests/temporal/test_temporal_foundation.py`, run
with caches cleared and `python -B`. Assertions use **literal** values rather
than reading from `RETRY_POLICIES`; a test that takes its expectation from the
thing under test cannot fail, which this package produced before in assertion 28.

| Mutation | Result |
|---|---|
| *(none — baseline)* | `OK` |
| `MODEL_RETRY` maximum_interval 20 → 25 | `policy='MODEL_RETRY'` · `25 != 20` |
| `IO_RETRY` attempts 5 → 3 | `activity_class='retrieval'` · `3 != 5` |
| `tool_call` remapped to `IO_RETRY` | `activity_class='tool_call'` · `'IO_RETRY' != 'SIDE_EFFECT_RETRY'` |
| `MODEL_RETRY` backoff 2.0 → 1.0 | `policy='MODEL_RETRY'` · `1.0 != 2.0` |
| spurious error type on `IO_RETRY` | `Tuples differ: ('Spurious',) != ()` |

Decision coverage — `scripts/check_decision_coverage.py`:

| Mutation | Result |
|---|---|
| *(none — baseline)* | every `[DECISION]` covered, enumeration agrees |
| a `[DECISION: ADR-0099]` reference | `names an ADR that does not exist` |
| ADR-0007 (cited from `policies.py`) set `Proposed` | `policies.py: ... which is not Accepted` |
| ADR-0005 (cited from the schema) set `Proposed` | `...derived.sql: ... which is not Accepted` |
| a declaration loses its `[DECISION]` tag | `lists 31 declaration(s) but the schema carries 30` |

## Gate evidence

### FND-SPEC2-G1 — every `[DECISION]` covered by an accepted ADR

`scripts/check_decision_coverage.py`, with the five controls above. ADR-0010
covers the 31 residual declarations: five reasoned individually because each
closes a domain, twenty-six approved as a class.

### FND-SPEC2-G2 — timeouts approved, retry policies encoded and applied

ADR-0007. `RETRY_POLICIES` in `policies.py` reproduces the four v1.2 policies;
`runtime.py` passes their intervals into the SDK; four new tests assert them
against literals and run without a Temporal server — deliberately, so they are
not another thing only CI can check.

### FND-SPEC2-G3 — `SRC-001` closed with each clause answered

The table at the top of this file, including the narrower version claim.

## What closing SRC-001 actually unlocked

`FND-DB-DOMAIN` moves `blocked` → `planned` with an empty blocker list. It is
**not** yet eligible, and it was worth stating that precisely rather than
claiming the stronger result:

```
FND-DB-DOMAIN  status: planned  blockers: []  deps: ['FND-DB-001']
  dependency FND-DB-001: planned
```

Eligibility needs `planned`/`ready` status, an `in_progress` phase, no blockers
**and every dependency complete** (`scripts/control_plane.py:500`). The gap was
one of two things holding it; `FND-DB-001` is the other, and remains. The
eligible set is unchanged by this package — which is the correct outcome, not a
shortfall.

## Safety and rollback

No schema, migration, cloud resource or Temporal namespace is created. The only
behavioural change is retry attempt counts for two activity classes, bounded by
unchanged `schedule_to_close` deadlines. Rollback is a Git revert plus setting
`SRC-001` back to `open`.
