# Evidence — FND-TEMP-001

## Scope

Work package: `FND-TEMP-001` — Temporal Foundation contracts and replay
safety.

This package establishes Continuum's durable execution boundary. Temporal owns
workflow execution continuity; external I/O remains in Activities, and cognitive
or tenant state remains outside Temporal.

## Design and dependency evidence

- Governing work package: `docs/implementation/work-packages/FND-TEMP-001.json`
- Implementation plan: `docs/superpowers/plans/2026-08-24-temporal-foundation.md`
- Completed dependency: `docs/implementation/work-packages/FND-CTRL-001.json`
- Pinned SDK/runtime: `pyproject.toml` and `uv.lock`
- CI contract: `.github/workflows/temporal-foundation.yml`

## TDD evidence

### Foundation RED

Initial GitHub Actions run:

`https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32798601587`

This run failed while the acceptance tests existed without the required
Foundation contract/runtime files.

### SDK execution RED

GitHub Actions run:

`https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32798796476`

This run failed after the SDK acceptance tests were added and before the real
Temporal worker execution path existed. A later regression gate also failed at:

`https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32842726184`

### Replay, failure-semantics, and rollback RED

The package's remaining tests were executed locally against the pinned Python
3.13/Temporal SDK environment before their implementations. The observed
failures were:

- no marker event in current Workflow history;
- no SDK Activity execution-options mapping;
- no stable Activity-context builder;
- no stable Worker Deployment config or rollback selector;
- Foundation Workflow versioning behavior was `UNSPECIFIED`, not `PINNED`.

The committed regression tests preserve those failure boundaries:

- `tests/temporal/test_temporal_replay.py`
- `tests/temporal/test_temporal_failure_semantics.py`
- `tests/temporal/test_worker_versioning.py`

### Implementation GREEN

Fresh GitHub Actions pull-request runs for commit
`a97407c4466eff6f3595724b319b972538411d84`:

- Temporal Foundation: `https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32843622281`
- Implementation Control Plane: `https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32843622338`

Verified log results:

- 19 Temporal tests — PASS;
- current patched history replay — PASS;
- pre-patch history replay against current code — PASS;
- retry/heartbeat/cancellation/idempotency policy tests — PASS;
- stable Worker Deployment and rollback tests — PASS;
- 14 control-plane tests — PASS;
- authoritative control-plane governance verification — PASS.

### Review-hardening GREEN

Independent review identified two runtime contract gaps: invalid input raised a
plain `ValueError`, leaving the Workflow Task retrying, and Worker Deployment
metadata omitted the actual `continuum.foundation` queue. The hardening pass
added integration regressions, converts expected validation failures to a
non-retryable `continuum.validation` `ApplicationError`, centralizes the queue,
and executes the Foundation Workflow with the generated versioned-worker
configuration.

Fresh pull-request runs for hardening commit
`2d14c8f087a687ffff4f5bd5777717b5612cb326`:

- Temporal Foundation: `https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32844413292`
- Implementation Control Plane: `https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32844413321`

These runs verified the package while `FND-TEMP-001` was already `complete`
with all four hard gates set to PASS. The Temporal suite contained 21 tests and
the control-plane suite contained 14 tests.

## Gate evidence

### FND-TEMP-G1 — deterministic Workflow/Activity boundary

- SDK Workflow and Activity definitions: `services/orchestrator/temporal/runtime.py`
- deterministic helpers: `services/orchestrator/temporal/workflows.py`
- Activity ownership boundary: `services/orchestrator/temporal/activities.py`
- real Worker execution test: `tests/temporal/test_temporal_execution.py`
- forbidden nondeterministic import test: `tests/temporal/test_temporal_foundation.py`

### FND-TEMP-G2 — replay and versioning safety

- stable patch identifier and compatibility branch:
  `services/orchestrator/temporal/workflows.py` and
  `services/orchestrator/temporal/runtime.py`
- generated current/pre-patch history replay:
  `tests/temporal/test_temporal_replay.py`
- history handling policy: `tests/temporal/history/README.md`

### FND-TEMP-G3 — execution and failure policies

- task queues, priority classes, retries, timeouts, heartbeat, cancellation,
  error classification, and Continue-As-New thresholds:
  `services/orchestrator/temporal/policies.py`
- SDK policy adapter: `services/orchestrator/temporal/runtime.py`
- stable idempotency key: `services/orchestrator/temporal/activities.py`
- policy behavior tests: `tests/temporal/test_temporal_failure_semantics.py`

### FND-TEMP-G4 — stable Worker Versioning and rollback

- Worker Deployment contract and stable SDK mapping:
  `services/orchestrator/temporal/worker.py`
- explicit pinned Workflow behavior:
  `services/orchestrator/temporal/runtime.py`
- rollback/versioning tests: `tests/temporal/test_worker_versioning.py`
- human-gated rollback procedure: `docs/runbooks/temporal-worker-rollback.md`

The pinned SDK version is `temporalio==1.31.0`. The implementation uses
`WorkerDeploymentConfig`, `WorkerDeploymentVersion`, and `VersioningBehavior`;
it does not enable the removed pre-2025 experimental Worker Versioning method.

## Safety and rollback

No Temporal namespace, worker fleet, database, or cloud resource is created by
this package. Repository rollback is a Git revert. Once deployed, runtime
rollback follows `docs/runbooks/temporal-worker-rollback.md` and requires an
explicit human routing decision after replay and health verification.

The PR remains draft and automatic merge remains disabled. The final
self-hosting CI run after this evidence and the completed work-package record
are committed must pass before the PR can be considered for human review.

## Post-completion correction — Continue-As-New thresholds

Gate `FND-TEMP-G3` was recorded `PASS` on the claim that Continue-As-New
thresholds were "encoded and tested". Subsequent repository review found the
encoded values did not match the v1.2 Temporal execution contract, and that the
test backing the claim could not detect the discrepancy.

### Defect

`CONTINUE_AS_NEW` was `max_events=100_000, max_age_seconds=7 * 24 * 3600`.
Temporal terminates a Workflow Execution once its Event History exceeds 51,200
events, so the Continue-As-New branch was unreachable on event count: a
long-running Workflow would be terminated by the server rather than continuing.
The v1.2 contract specifies `>8,000` history events or recurring execution
`>24h`, with 8,000 chosen as a conservative Continuum threshold that preserves
headroom below the platform limit.

### Faulty evidence

`test_continue_as_new_thresholds_are_exact` asserted the boundary using
`CONTINUE_AS_NEW.max_events` and `CONTINUE_AS_NEW.max_age_seconds` as its own
inputs. A boundary asserted in terms of the constant that defines it holds for
any value, so the test passed against the incorrect thresholds. The companion
assertion in `test_temporal_foundation.py` checked only `> 0`.

### Correction

- `CONTINUE_AS_NEW` is now `max_events=8_000, max_age_seconds=24 * 3600`.
- `TEMPORAL_HISTORY_TERMINATION_EVENTS = 51_200` is named explicitly, and
  `ContinueAsNewPolicy.__post_init__` rejects any threshold at or above it. An
  unreachable Continue-As-New policy now fails at import rather than silently.
- `test_continue_as_new_thresholds_match_the_v12_contract` asserts literal
  values; `test_continue_as_new_threshold_stays_below_temporal_termination`
  guards the platform limit; `test_continue_as_new_boundary_behavior` asserts
  the 7,999/8,000 and 86,399/86,400 boundaries directly.

Both regressions were verified to fail against the previous values: 100,000 is
rejected at import, and an off-spec-but-legal 20,000 fails the literal and
boundary assertions.

This correction does not re-open the work package. It records that
`FND-TEMP-G3`'s original evidence was insufficient and that the gate's stated
claim is now actually enforced.

The correction is tracked as its own work package, `FND-TEMP-002`, with its own
hard gates and evidence: `docs/implementation/work-packages/FND-TEMP-002.json`
and `docs/implementation/evidence/FND-TEMP-002.md`.
