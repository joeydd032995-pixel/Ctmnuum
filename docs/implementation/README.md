# Continuum Implementation Control Plane

This directory is the repository-native control state for building Continuum from the v1.2 implementation specification and phase-by-phase execution plan.

## Authoritative files

- `requirements.json` — immutable requirement IDs with source/provenance.
- `phases.json` — ordered implementation phases and phase-level hard gates.
- `source-gaps.json` — missing or unresolved source material that must not be silently invented.
- `work-packages/*.json` — dependency-aware units of implementation work.
- `evidence/` — repository evidence referenced by passing gates.

The work-package contract is documented by `schemas/implementation-work-package.schema.json`.

The control plane has two code layers:

- `scripts/control_plane.py` — core loading, structural validation, dependency checks, evidence validation, report rendering, and eligibility primitives.
- `scripts/control_plane_policy.py` — the **authoritative enforcement CLI**. It combines the core engine with cross-registry governance such as strict phase ordering, inactive-phase completion prevention, and automatic source-gap blocking.

## Commands

Use the policy CLI for project decisions and CI. Invoke repository CLIs as Python modules so package imports resolve consistently in local and CI environments:

```bash
python -m scripts.control_plane_policy verify
python -m scripts.control_plane_policy report
python -m scripts.control_plane_policy next
```

`verify` returns non-zero for invalid state, unknown references, dependency cycles, illegal phase/package progression, incomplete hard gates, missing evidence, unresolved blockers, source-gap bypasses, invalid phase predecessor chains, or premature autonomous-capability activation.

`report` prints a Markdown status report suitable for CI artifacts and PR comments. Open source gaps are applied as effective blockers before the report is rendered.

`next` prints only work packages whose dependencies are complete, blockers are empty, owning phase is active, and no open source gap blocks the package.

The lower-level core CLI remains available for debugging structural validation:

```bash
python -m scripts.control_plane verify
python -m scripts.control_plane report
python -m scripts.control_plane next
```

It MUST NOT be used as the authoritative merge/progression gate because it intentionally excludes cross-registry policy enforcement.

## Work-package lifecycle

```text
planned
  │
  ├── dependencies complete + phase active + no open source-gap block
  ▼
ready
  ▼
in_progress
  ├── blocker discovered ─────────► blocked
  │                                  │
  │                                  └── blocker resolved ─► ready/in_progress
  │
  └── all hard gates PASS + evidence + no blockers
                                     ▼
                                  complete
```

A package may remain `planned` even when technically eligible; `next` will still surface it. `ready` is an explicit declaration that dependency and blocker checks have been satisfied and implementation may begin.

A package cannot be marked `complete` while its owning phase is inactive. An open source gap that lists a work-package ID in its `blocks` array is an effective blocker even if someone omits that gap from the package record; the verifier also requires the explicit blocker relationship to be reflected in the package.

## Acceptance gates

Hard gates cannot be waived. A hard gate marked `PASS` must contain at least one evidence item. Evidence is one of:

```json
{"path": "tests/path/to/evidence.md"}
```

or:

```json
{"external_ref": "https://github.com/.../actions/runs/..."}
```

Repository paths are verified to exist and may not escape the repository root.

## Source provenance

A requirement is classified as one of:

- `v1.2` — directly sourced from the Continuum v1.2 specification/execution plan;
- `adr` — an explicit architecture decision record;
- `local-policy` — an approved implementation/governance rule added after v1.2.

If exact v1.2 implementation detail is missing, create or update a source-gap record and, when implementation must proceed, document the chosen behavior in an ADR. Do not present reconstructed behavior as recovered source text.

## Phase progression

The phase order is:

1. Foundation
2. Persistent Reasoning
3. Memory
4. Reliability
5. Actions
6. Self-extension
7. Evolution

Phase orders must remain contiguous. Each phase after Foundation must name the immediately preceding phase as its predecessor. Only one phase may be `in_progress`. A later phase cannot become `in_progress` or `accepted` until its predecessor is `accepted`.

Autonomous/self-modifying capability remains disabled until the Evolution phase itself is accepted after all predecessor phases and safety gates have passed.

## GitHub behavior

`.github/workflows/implementation-control-plane.yml` runs on implementation branches and pull requests to `main`.

It:

1. runs the control-plane unit tests;
2. runs the authoritative policy verifier;
3. generates a Markdown status report;
4. uploads the report as an Actions artifact;
5. creates or updates one marker-delimited PR status comment.

The workflow uses no repository secrets and does not merge pull requests. Merge remains a human-controlled gate.
