# Evidence — FND-TEMP-002

## Scope

Work package: `FND-TEMP-002` — Continue-As-New threshold correction and
non-tautological policy evidence.

This package corrects a defect in work delivered by `FND-TEMP-001` and the
insufficient test evidence that allowed the defect to pass a hard gate. It does
not re-open `FND-TEMP-001`, which remains `complete`; it is recorded separately
so the correction carries its own gates and its own evidence.

## Defect

`CONTINUE_AS_NEW` was configured as:

```python
CONTINUE_AS_NEW = ContinueAsNewPolicy(
    max_events=100_000,
    max_age_seconds=7 * 24 * 3600,
)
```

Temporal terminates a Workflow Execution once its Event History exceeds 51,200
events, and emits a warning from 10,240 onward. A Continue-As-New threshold of
100,000 events is therefore unreachable: a long-running Workflow would be
terminated by the server before the continue branch could be taken.

The v1.2 Temporal execution contract specifies Continue-As-New at `>8,000`
history events or recurring execution `>24h`, and states explicitly that 8,000
is an intentionally conservative Continuum threshold rather than a Temporal
platform maximum. The encoded value inverted that intent.

## Why the original evidence did not catch it

Gate `FND-TEMP-G3` was recorded `PASS` on the claim that Continue-As-New
policies were "encoded and tested". The supporting test was:

```python
def test_continue_as_new_thresholds_are_exact(self) -> None:
    self.assertFalse(
        should_continue_as_new(
            event_count=CONTINUE_AS_NEW.max_events - 1,
            age_seconds=CONTINUE_AS_NEW.max_age_seconds - 1,
        )
    )
    ...
```

The boundary is asserted in terms of the constant that defines it, so the
assertion holds for any value the constant takes. The companion assertion in
`test_temporal_foundation.py` checked only `assertGreater(max_events, 0)`.

Both tests passed against the incorrect thresholds and would have passed
against any incorrect threshold. This is the failure mode `CONT-V12-GOV-003`
exists to prevent: a hard gate whose evidence cannot distinguish a correct
implementation from an incorrect one.

## Correction

- `CONTINUE_AS_NEW` is now `max_events=8_000, max_age_seconds=24 * 3600`.
- `TEMPORAL_HISTORY_TERMINATION_EVENTS = 51_200` is named explicitly, and
  `ContinueAsNewPolicy.__post_init__` raises `ValueError` for any threshold at
  or above it. An unreachable policy now fails at import rather than silently.
- The tautological assertions are replaced by:
  - `test_continue_as_new_thresholds_match_the_v12_contract` — literal values;
  - `test_continue_as_new_threshold_stays_below_temporal_termination` — the
    platform-limit guard, including the rejection path;
  - `test_continue_as_new_boundary_behavior` — the 7,999/8,000 and
    86,399/86,400 boundaries asserted directly.

## Regression proof

Both regressions were verified to fail against the previous values before the
correction was committed.

Reverting `max_events` to `100_000`:

```
ValueError: max_events=100000 is at or above Temporal's history termination
limit (51200); the Continue-As-New branch could never be reached
```

The module cannot be imported, so no test using it can vacuously pass.

Setting `max_events` to `20_000` — below the platform limit but off-contract:

```
AssertionError: 20000 != 8000
AssertionError: False is not true
Ran 7 tests ... FAILED (failures=2)
```

This second case is the one the platform guard alone would not catch, and is
why the literal and boundary assertions exist alongside it.

## Review finding — threshold comparison was not strict

Automated review on the pull request identified that `should_continue_as_new`
compares with `>=`:

```python
event_count >= CONTINUE_AS_NEW.max_events
or age_seconds >= CONTINUE_AS_NEW.max_age_seconds
```

The v1.2 contract is strict — Continue-As-New *above* 8,000 history events or
*above* 24h of recurring execution. With `>=`, an execution at exactly 8,000
events or exactly 86,400 seconds triggers one event and one second early, at the
threshold rather than beyond it.

The `>=` comparison predates this package, but this package is what documented
the threshold as `>8,000` / `>24h` and added boundary assertions at exactly
8,000 and 86,400 — which would have locked the off-by-one in as intended
behavior. The finding is accepted.

`should_continue_as_new` now uses strict `>`, and the boundary assertions are
corrected: the threshold value itself must not trigger, and only the first value
beyond it does.

```
events= 8000 age=     0 -> False
events= 8001 age=     0 -> True
events=    0 age= 86400 -> False
events=    0 age= 86401 -> True
```

The helper is not yet wired into `FoundationWorkflow`, so the change has no
runtime effect on any executing Workflow; it is a contract-fidelity correction.

The platform guard in `ContinueAsNewPolicy.__post_init__` keeps `>=` against
`TEMPORAL_HISTORY_TERMINATION_EVENTS`, which remains correct: a threshold equal
to the termination limit would only fire above it, and is therefore still
unreachable.

## Gate evidence

### FND-TEMP2-G1 — contract-correct thresholds, literally asserted

- `services/orchestrator/temporal/policies.py` — `CONTINUE_AS_NEW`
- `tests/temporal/test_temporal_failure_semantics.py` —
  `test_continue_as_new_thresholds_match_the_v12_contract`,
  `test_continue_as_new_boundary_behavior`
- `tests/temporal/test_temporal_foundation.py` — literal assertions replacing
  the previous `> 0` checks

### FND-TEMP2-G2 — unreachable policy rejected at construction

- `services/orchestrator/temporal/policies.py` —
  `TEMPORAL_HISTORY_TERMINATION_EVENTS`, `ContinueAsNewPolicy.__post_init__`
- `tests/temporal/test_temporal_failure_semantics.py` —
  `test_continue_as_new_threshold_stays_below_temporal_termination`

### FND-TEMP2-G3 — insufficient prior evidence documented

- `docs/implementation/evidence/FND-TEMP-002.md` (this document)
- `docs/implementation/evidence/FND-TEMP-001.md` — post-completion correction
  section recording that `FND-TEMP-G3`'s original evidence was insufficient

## Safety and rollback

No Temporal namespace, worker fleet, database, or cloud resource is touched. No
deployed Workflow Execution exists, so there is no running execution to migrate
and no history-format implication.

Repository rollback is a Git revert, but note that reverting restores the
unreachable threshold and is therefore not a safe resting state; a revert
should be paired with an alternative correction.
