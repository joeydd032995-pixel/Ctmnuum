# Temporal Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish Temporal as Continuum's durable execution layer with deterministic workflow boundaries, explicit Activity ownership, replay-safe contracts, encoded execution policies, and a tested rollback path.

**Architecture:** Temporal owns durable execution state only. Workflow code remains deterministic and side-effect free; external I/O belongs to Activities. Continuum's cognitive/system state remains outside Temporal. Foundation introduces versioned contracts and worker deployment metadata without depending on preview-only features.

**Tech Stack:** Python 3.13, Temporal Python SDK, unittest/Temporal test utilities, GitHub Actions.

**Spec:** `docs/implementation/work-packages/FND-TEMP-001.json`

## Global Constraints

- `CONT-V12-GOV-001`: implementation phases MUST advance in dependency order and hard gates MUST pass before advancement.
- `CONT-V12-GOV-003`: completion MUST have objective, machine-verifiable evidence where practical.
- `CONT-V12-TEMP-001`: Temporal MUST be the durable execution layer with deterministic workflow boundaries before higher-level reasoning depends on it.
- No production workflow may depend on preview-only Temporal features.
- Human merge only; no auto-merge.

---

### Task 1: Foundation contract surface

**Files:**
- Create: `services/orchestrator/temporal/contracts.py`
- Create: `services/orchestrator/temporal/policies.py`
- Create: `services/orchestrator/temporal/workflows.py`
- Create: `services/orchestrator/temporal/activities.py`
- Create: `services/orchestrator/temporal/worker.py`
- Test: `tests/temporal/test_temporal_foundation.py`

**Interfaces:**
- Produces: `ActivityContext`, `WorkflowRequest`, `WorkflowResult`, queue/policy constants, `should_continue_as_new()`, Activity boundary, worker deployment contract.

- [x] Write failing contract tests.
- [x] Verify RED in GitHub Actions.
- [x] Implement minimal contract surface.
- [x] Verify GREEN in GitHub Actions.

### Task 2: Real Temporal SDK runtime and deterministic workflow

**Files:**
- Create: `pyproject.toml`
- Create: `services/orchestrator/temporal/runtime.py`
- Modify: `services/orchestrator/temporal/workflows.py`
- Modify: `services/orchestrator/temporal/activities.py`
- Test: `tests/temporal/test_temporal_runtime.py`
- Modify: `.github/workflows/temporal-foundation.yml`

**Interfaces:**
- Consumes: Foundation dataclasses and policy constants.
- Produces: SDK `@workflow.defn` workflow and `@activity.defn` Activities, test-environment execution path.

- [ ] Write failing SDK runtime tests.
- [ ] Verify RED.
- [ ] Add pinned Temporal SDK dependency and runtime implementation.
- [ ] Execute workflow in Temporal test environment.
- [ ] Verify GREEN.

### Task 3: Replay and versioning safety

**Files:**
- Create: `tests/temporal/test_temporal_replay.py`
- Create: `tests/temporal/history/README.md`
- Modify: `services/orchestrator/temporal/workflows.py`

**Interfaces:**
- Produces: version-safe workflow behavior and replay verification entrypoint.

- [ ] Write replay/versioning test that fails without explicit compatibility mechanism.
- [ ] Verify RED.
- [ ] Implement the smallest stable SDK-supported versioning/patching mechanism needed by the Foundation workflow.
- [ ] Generate/capture a deterministic test history through the SDK test environment.
- [ ] Replay history against current workflow implementation.
- [ ] Verify GREEN.

### Task 4: Retry, timeout, heartbeat, cancellation, idempotency, Continue-As-New

**Files:**
- Modify: `services/orchestrator/temporal/policies.py`
- Modify: `services/orchestrator/temporal/workflows.py`
- Modify: `services/orchestrator/temporal/activities.py`
- Create: `tests/temporal/test_temporal_failure_semantics.py`

**Interfaces:**
- Produces: encoded policy-to-SDK mapping and observable retry/failure behavior.

- [ ] Write failing tests for retry classification and maximum attempts.
- [ ] Write failing tests for long-running heartbeat/cancellation settings.
- [ ] Write failing test proving duplicate Activity execution uses stable idempotency key.
- [ ] Write failing test for Continue-As-New threshold decision.
- [ ] Implement minimal mappings and behavior.
- [ ] Verify all failure-semantics tests GREEN.

### Task 5: Worker deployment/versioning rollback

**Files:**
- Modify: `services/orchestrator/temporal/worker.py`
- Create: `tests/temporal/test_worker_versioning.py`
- Create: `docs/runbooks/temporal-worker-rollback.md`

**Interfaces:**
- Produces: stable build/deployment metadata and documented rollback procedure.

- [ ] Write failing rollback/versioning tests.
- [ ] Verify RED.
- [ ] Implement stable worker-version metadata and previous-build rollback selection.
- [ ] Verify no runtime flag enables preview-only features.
- [ ] Document rollback runbook.
- [ ] Verify GREEN.

### Task 6: Evidence and control-plane completion

**Files:**
- Create: `docs/implementation/evidence/FND-TEMP-001.md`
- Modify: `docs/implementation/work-packages/FND-TEMP-001.json`

**Interfaces:**
- Produces: hard-gate evidence for `FND-TEMP-G1` through `FND-TEMP-G4`.

- [ ] Run complete Temporal test suite from a fresh CI execution.
- [ ] Run implementation-control verification.
- [ ] Record RED and GREEN workflow URLs plus replay/failure/rollback evidence.
- [ ] Change each hard gate to PASS only when its evidence exists.
- [ ] Mark `FND-TEMP-001` complete only after all hard gates pass.
- [ ] Keep PR draft until final review and verification are complete.

## Self-review

- Spec coverage: all four FND-TEMP hard gates map to Tasks 2–5 and final evidence Task 6.
- No production state ownership is assigned to Temporal beyond execution continuity.
- No preview-only capability is required.
- Database/Neon work is intentionally excluded from this package.
- Human merge remains the terminal gate.
