# Continuum Implementation Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repository-native implementation control plane that enforces phase order, work-package dependencies, source traceability, hard acceptance gates, evidence, and human-controlled merges.

**Architecture:** Machine-readable JSON state under `docs/implementation/` is validated by a dependency-free Python 3.13 CLI. GitHub Actions runs unit tests and verification on every PR, generates a report artifact, and comments the current gate state without using secrets or auto-merge authority.

**Tech Stack:** Python 3.13 standard library, JSON, JSON Schema documentation, GitHub Actions, GitHub issue/PR templates.

**Spec:** `docs/superpowers/specs/2026-08-24-implementation-control-plane-design.md`

## Global Constraints

- The control plane MUST remain independent from Continuum production runtime orchestration.
- It MUST NOT require Temporal, PostgreSQL, Redis, AWS, Vercel, or third-party Python packages to run.
- It MUST fail closed on unknown requirement/dependency/gate references.
- Hard gates MUST NOT be waivable.
- Complete work packages MUST have passing hard gates, evidence, and no blockers.
- Later phases MUST NOT activate before predecessor phase acceptance.
- Autonomous/self-modifying capabilities MUST remain disabled until their gated phase is accepted.
- Pull requests MUST remain human-merged; no auto-merge logic is introduced.

---

### Task 1: Define verifier behavior with failing tests

**Files:**
- Create: `tests/control_plane/test_control_plane.py`
- Create: `.github/workflows/implementation-control-plane.yml`

**Interfaces:**
- Consumes: repository control-plane JSON files and `scripts.control_plane` module.
- Produces: executable acceptance tests and CI contract.

- [ ] **Step 1: Write tests that import `scripts.control_plane` and cover repository verification, dependency-cycle rejection, complete-package evidence enforcement, and eligible-next selection.**

- [ ] **Step 2: Add GitHub Actions workflow using Python 3.13.**

- [ ] **Step 3: Open a draft PR and verify the workflow fails because `scripts/control_plane.py` is absent.**

- [ ] **Step 4: Record the RED run URL in the PR discussion.**

### Task 2: Add machine-readable registries and schemas

**Files:**
- Create: `docs/implementation/requirements.json`
- Create: `docs/implementation/phases.json`
- Create: `docs/implementation/source-gaps.json`
- Create: `docs/implementation/work-packages/FND-CTRL-001.json`
- Create: `docs/implementation/work-packages/FND-TEMP-001.json`
- Create: `schemas/implementation-work-package.schema.json`
- Create: `docs/implementation/README.md`

**Interfaces:**
- Consumes: approved control-plane design and v1.2 phase-gating invariants.
- Produces: canonical repository implementation state.

- [ ] **Step 1: Seed the seven phases in strict order.**
- [ ] **Step 2: Seed requirement IDs for phase gating, evidence-backed completion, and delayed autonomous activation.**
- [ ] **Step 3: Record the missing machine-readable v1.2 core artifact as an open source gap.**
- [ ] **Step 4: Seed `FND-CTRL-001` and `FND-TEMP-001`.**
- [ ] **Step 5: Document the work-package JSON contract.**

### Task 3: Implement the dependency-free verifier and report generator

**Files:**
- Create: `scripts/__init__.py`
- Create: `scripts/control_plane.py`

**Interfaces:**
- Consumes: JSON registries under `docs/implementation/`.
- Produces:
  - `verify_repository(root: Path) -> list[str]`
  - `load_control_state(root: Path) -> ControlState`
  - `eligible_work_packages(state: ControlState) -> list[dict[str, object]]`
  - `render_report(state: ControlState, errors: list[str]) -> str`
  - CLI commands `verify`, `report`, `next`.

- [ ] **Step 1: Implement JSON loading and required-field/type checks.**
- [ ] **Step 2: Implement duplicate/unknown-reference validation.**
- [ ] **Step 3: Implement dependency-cycle detection.**
- [ ] **Step 4: Implement phase-progression checks.**
- [ ] **Step 5: Implement work-package status/gate/evidence checks.**
- [ ] **Step 6: Implement autonomous-capability gating.**
- [ ] **Step 7: Implement eligible-next calculation.**
- [ ] **Step 8: Implement Markdown report rendering and CLI exit codes.**
- [ ] **Step 9: Run `python -m unittest discover -s tests/control_plane -p 'test_*.py' -v` and require PASS.**
- [ ] **Step 10: Run `python scripts/control_plane.py verify` and require exit code 0.**

### Task 4: Add GitHub contribution contracts and status automation

**Files:**
- Create: `.github/pull_request_template.md`
- Create: `.github/ISSUE_TEMPLATE/work-package.yml`
- Modify: `.github/workflows/implementation-control-plane.yml`

**Interfaces:**
- Consumes: work-package IDs and verifier output.
- Produces: standardized implementation issues/PRs and an automated PR status comment.

- [ ] **Step 1: Require work-package ID, requirement IDs, risk class, rollback, blockers, and gate evidence in the PR template.**
- [ ] **Step 2: Create a GitHub issue form with the same fields for new work packages.**
- [ ] **Step 3: Make CI generate `control-plane-report.md`.**
- [ ] **Step 4: Upload the report with `actions/upload-artifact@v4`.**
- [ ] **Step 5: On same-repository PRs only, use `actions/github-script@v7` to create/update one marker-delimited status comment.**
- [ ] **Step 6: Keep workflow permissions to `contents: read`, `pull-requests: write`, and `issues: write`; do not expose secrets.**

### Task 5: Close the self-hosting loop and verify the PR

**Files:**
- Modify: `docs/implementation/work-packages/FND-CTRL-001.json`
- Create: `docs/implementation/evidence/FND-CTRL-001.md`

**Interfaces:**
- Consumes: passing CI runs and repository files.
- Produces: a self-verified completed control-plane work package and merge-ready PR.

- [ ] **Step 1: Mark each `FND-CTRL-001` hard gate PASS only after its evidence exists.**
- [ ] **Step 2: Add repository-path evidence for tests/spec/schema/workflow and stable external reference for the passing CI run.**
- [ ] **Step 3: Set `FND-CTRL-001.status` to `complete`.**
- [ ] **Step 4: Run the full test suite and verifier from a fresh commit.**
- [ ] **Step 5: Confirm `python scripts/control_plane.py next` lists `FND-TEMP-001`.**
- [ ] **Step 6: Confirm the PR control-plane status comment reports no errors and all `FND-CTRL-001` hard gates PASS.**
- [ ] **Step 7: Mark the PR ready for review; do not merge it.**
