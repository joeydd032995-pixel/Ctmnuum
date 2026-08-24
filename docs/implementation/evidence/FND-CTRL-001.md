# Evidence — FND-CTRL-001

## Scope

Work package: `FND-CTRL-001` — Repository-native implementation control plane.

This package creates repository-only implementation governance. It provisions no cloud resources, stores no secrets, and does not enable automatic merge authority.

## Design and plan evidence

- Design: `docs/superpowers/specs/2026-08-24-implementation-control-plane-design.md`
- Implementation plan: `docs/superpowers/plans/2026-08-24-implementation-control-plane.md`
- Work-package schema: `schemas/implementation-work-package.schema.json`
- Control state documentation: `docs/implementation/README.md`

## TDD evidence

### RED

GitHub Actions run:

`https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32785354218`

The unit-test step failed before implementation with:

`ModuleNotFoundError: No module named 'scripts'`

This demonstrated that the control-plane acceptance test could not pass before the verifier existed.

### First GREEN

GitHub Actions run:

`https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32785787899`

Verified steps:

- control-plane unit tests — PASS
- repository control-state verification — PASS
- Markdown status report generation — PASS
- Actions artifact upload — PASS
- PR status comment publication — PASS

### Self-hosting GREEN

GitHub Actions run:

`https://github.com/joeydd032995-pixel/Ctmnuum/actions/runs/32785980767`

This run verified the repository after `FND-CTRL-001` was marked complete with all four hard gates PASS. The generated control-plane report identified `FND-TEMP-001` as the next eligible Foundation package.

## Review hardening

A manual final-diff review identified three policy bypasses that were not covered by the first implementation:

1. a work package could be set directly to `complete` while its owning phase was inactive;
2. a source gap could declare that it blocked a package without that relationship being enforced by eligibility logic;
3. phase ordering did not require the predecessor chain to exactly follow the numeric phase order.

The hardening pass added `scripts/control_plane_policy.py` and tests that reject all three cases. The policy layer is now the authoritative CI/CLI entry point, while `scripts/control_plane.py` remains the structural core.

## Implementation evidence

- Core verifier/report/eligibility primitives: `scripts/control_plane.py`
- Authoritative cross-registry governance: `scripts/control_plane_policy.py`
- Tests: `tests/control_plane/test_control_plane.py`
- CI: `.github/workflows/implementation-control-plane.yml`
- Requirement registry: `docs/implementation/requirements.json`
- Phase registry: `docs/implementation/phases.json`
- Source-gap registry: `docs/implementation/source-gaps.json`
- Control-plane work package: `docs/implementation/work-packages/FND-CTRL-001.json`
- Next Temporal work package: `docs/implementation/work-packages/FND-TEMP-001.json`
- PR contract: `.github/pull_request_template.md`
- Work-package issue contract: `.github/ISSUE_TEMPLATE/work-package.yml`

## Safety / rollback evidence

The control plane does not create or mutate persistent external infrastructure. Rollback is a Git revert of this PR. The workflow uses the `pull_request` event, receives only scoped `GITHUB_TOKEN` permissions, uses no repository secrets, and contains no auto-merge operation.

## Final self-hosting gate

The merge candidate must prove all of the following simultaneously:

1. `python -m scripts.control_plane_policy verify` returns zero errors;
2. all `FND-CTRL-001` hard gates are `PASS` with evidence;
3. `FND-CTRL-001` is `complete`;
4. `python -m scripts.control_plane_policy next` identifies `FND-TEMP-001` as eligible;
5. the final GitHub Actions run passes after the review-hardening changes;
6. external PR review has no unresolved merge-blocking findings.

The final post-hardening CI run and external-review result are recorded in the PR discussion/status checks before merge readiness is claimed.
