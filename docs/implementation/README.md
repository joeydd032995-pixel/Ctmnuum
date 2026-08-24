# Continuum Implementation Control Plane

This directory is the repository-native control state for building Continuum from the v1.2 implementation specification and phase-by-phase execution plan.

## Authoritative files

- `requirements.json` — immutable requirement IDs with source/provenance.
- `phases.json` — ordered implementation phases and phase-level hard gates.
- `source-gaps.json` — missing or unresolved source material that must not be silently invented.
- `work-packages/*.json` — dependency-aware units of implementation work.
- `evidence/` — repository evidence referenced by passing gates.

The work-package contract is documented by `schemas/implementation-work-package.schema.json` and enforced by `scripts/control_plane.py`.

## Commands

```bash
python scripts/control_plane.py verify
python scripts/control_plane.py report
python scripts/control_plane.py next
```

`verify` returns non-zero for invalid state, unknown references, dependency cycles, illegal phase/package progression, incomplete hard gates, missing evidence, unresolved blockers on completed packages, or premature autonomous-capability activation.

`report` prints a Markdown status report suitable for CI artifacts and PR comments.

`next` prints only work packages whose dependencies are complete, blockers are empty, and owning phase is active.

## Work-package lifecycle

```text
planned
  │
  ├── dependencies complete + phase active
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

A package may remain `planned` even when technically eligible; `next` will still surface it. `ready` is an explicit declaration that dependency checks have been satisfied and implementation may begin.

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

Only one phase may be `in_progress`. A later phase cannot become `in_progress` or `accepted` until its predecessor is `accepted`.

Autonomous/self-modifying capability remains disabled until the Evolution phase itself is accepted after all predecessor phases and safety gates have passed.

## GitHub behavior

`.github/workflows/implementation-control-plane.yml` runs on implementation branches and pull requests to `main`.

It:

1. runs the control-plane unit tests;
2. verifies repository state;
3. generates a Markdown status report;
4. uploads the report as an Actions artifact;
5. creates or updates one marker-delimited PR status comment.

The workflow uses no repository secrets and does not merge pull requests. Merge remains a human-controlled gate.
