# Continuum Implementation Control Plane Design

## Goal

Create a repository-native implementation control plane that makes Continuum work packages traceable, dependency-aware, test-gated, evidence-backed, and resistant to undocumented architectural drift.

## Scope

The control plane governs project implementation. It does not orchestrate Continuum's production runtime and does not replace Temporal.

It MUST:

1. assign immutable IDs to requirements, phases, work packages, source gaps, and acceptance gates;
2. record the source/provenance for every normative requirement;
3. model work-package dependencies and reject dependency cycles;
4. reject completion when required gates have not passed;
5. require evidence for every passing hard gate;
6. prevent a package from entering `in_progress` when its dependencies are incomplete;
7. prevent a later phase from becoming active before its predecessor phase is accepted;
8. keep autonomous/self-modifying phases disabled until their prerequisite phases and safety gates are accepted;
9. generate a human-readable status report from machine-readable state;
10. run in GitHub Actions without secrets or external services;
11. never auto-merge a pull request.

## Architecture

The authoritative control state is stored as JSON under `docs/implementation/`. JSON is chosen over YAML for the first version so the verifier can use only the Python standard library and remain executable before the Foundation dependency stack is installed.

The control plane consists of four parts:

- **Registry data** — requirements, phases, source gaps, and work packages.
- **Verifier** — a dependency-free Python CLI that validates structure, references, state transitions, hard gates, and evidence.
- **GitHub enforcement** — a workflow that runs tests and verification on pushes and pull requests and publishes a status artifact/comment.
- **Contribution contracts** — PR and issue templates that require work-package IDs, requirement IDs, gate evidence, risk, and rollback information.

## Data model

### Requirement

Required fields:

- `id`
- `statement`
- `level` (`MUST`, `SHOULD`, `MAY`)
- `source`
- `source_kind` (`v1.2`, `adr`, `local-policy`)
- `status` (`active`, `superseded`)

### Phase

Required fields:

- `id`
- `name`
- `order`
- `status` (`planned`, `in_progress`, `blocked`, `accepted`)
- `predecessor`
- `acceptance_gates`
- `autonomous_capability_allowed`

Only one phase may be `in_progress`. A phase with a predecessor may not be `in_progress` or `accepted` unless its predecessor is `accepted`.

### Work package

Required fields:

- `id`
- `phase`
- `title`
- `status` (`planned`, `ready`, `in_progress`, `blocked`, `complete`)
- `risk` (`low`, `medium`, `high`, `critical`)
- `source_requirements`
- `dependencies`
- `acceptance_gates`
- `blockers`
- `rollback`

`high` and `critical` packages require `approval_required: true`.

A work package may be `ready` only when all dependencies are complete. It may be `in_progress` only when all dependencies are complete and the owning phase is `in_progress`. It may be `complete` only when all hard acceptance gates have status `PASS`, every passing hard gate has evidence, and blockers are empty.

### Acceptance gate

Required fields:

- `id`
- `description`
- `hard`
- `status` (`PENDING`, `PASS`, `FAIL`, `WAIVED`)
- `evidence`

A hard gate may not be `WAIVED`. Evidence entries are either repository paths or stable external references. Repository-path evidence must exist.

### Source gap

Required fields:

- `id`
- `description`
- `status` (`open`, `resolved`)
- `severity`
- `blocks`
- `tracking`

Source gaps are explicit and may block selected work packages without blocking unrelated work.

## Verification rules

`python scripts/control_plane.py verify` MUST fail non-zero when any of the following occurs:

- invalid/missing required fields;
- duplicate IDs;
- unknown requirement, phase, dependency, or source-gap references;
- dependency cycle;
- illegal phase progression;
- illegal work-package progression;
- complete package with a pending/failed hard gate;
- complete package with missing evidence;
- evidence path does not exist;
- active blocker on a complete package;
- high/critical package without explicit approval requirement;
- autonomous capability enabled before the Evolution phase and prerequisite safety phases are accepted.

## Reporting

`python scripts/control_plane.py report` prints Markdown with:

- current phase;
- phase status table;
- work-package status table;
- next eligible work packages;
- open source gaps;
- failing/pending hard gates.

`python scripts/control_plane.py next` prints only work packages eligible to start.

## GitHub workflow

The workflow runs on pushes to implementation branches and pull requests to `main`.

Steps:

1. checkout;
2. Python 3.13 setup;
3. unit tests;
4. `control_plane.py verify`;
5. generate Markdown report;
6. upload report artifact;
7. on same-repository PRs, create or update a single control-plane status comment.

The workflow uses `pull_request`, not `pull_request_target`, and receives no repository secrets.

## Merge policy

The control plane provides evidence, not autonomous merge authority. PR merge remains a human gate. The repository should later configure the control-plane workflow as a required status check on `main`.

## Initial seeded state

The first PR seeds:

- all seven v1.2 implementation phases;
- governance requirements for phase gating and delayed autonomous activation;
- the known missing v1.2 core-artifact source gap;
- `FND-CTRL-001` as the control-plane package;
- `FND-TEMP-001` as the next eligible Foundation package once this PR is merged.

## Non-goals

- no Temporal workflow orchestration;
- no database provisioning;
- no cloud deployment;
- no automatic code generation;
- no automatic PR merge;
- no external project-management SaaS dependency.
