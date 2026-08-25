# Evidence — FND-CTRL-002

## Scope

Work package: `FND-CTRL-002` — Source-gap reference integrity and complete
Foundation work-package registry.

This package closes two governance defects found by repository review. Both
caused the control plane to report a healthier state than the repository was
actually in. `FND-CTRL-001` remains `complete` and is not re-opened.

## Defect 1 — a source gap could block nothing

`docs/implementation/source-gaps.json` recorded:

```json
{"id": "SRC-001", "status": "open", "blocks": ["FND-DB-DOMAIN"], ...}
```

No work package with the ID `FND-DB-DOMAIN` existed. The policy layer resolves
gap references only while iterating registered packages:

```python
package = state.work_packages.get(package_id)
if package is None:
    continue
```

so the reference was inert. `SRC-001` — the blocker tied to the project's one
open issue, and the reason domain DDL must not be invented — enforced nothing,
and `verify` returned PASS.

The repository README states that `verify` returns non-zero for "unknown
references". For source-gap `blocks` entries that was not implemented.

### Correction

`policy_errors` now validates every `blocks` entry against the work-package
registry, independent of gap status. A gap naming an unregistered package is a
verification error:

```
source gap SRC-001: blocks unknown work package 'FND-DB-DOMAIN'; a gap that
blocks a package which does not exist enforces nothing
```

Validation is applied to resolved gaps as well as open ones: a dangling
reference left behind by a deleted or renamed package is still a dead control,
and registry integrity should not depend on gap status.

## Defect 2 — an incomplete registry read as an all-clear

Only `FND-CTRL-001` and `FND-TEMP-001` were registered. The v1.2 Foundation
phase names ten work packages. Because the registry is the only thing the
control plane can observe, the report printed:

```
Next eligible work packages
- None
```

alongside `Verification: PASS`, which reads as *Foundation is finished* rather
than *Foundation is largely unrecorded*. The phase gate `PH-FND-G1` correctly
remained `PENDING`, but nothing surfaced the gap between "all registered work is
done" and "the phase is done".

### Correction

Ten Foundation work packages are registered, each with hard gates transcribed
from the v1.2 execution plan and Foundation acceptance criteria:

| ID | Scope |
| --- | --- |
| `FND-REPO-001` | Monorepo, build tooling, lockfile baseline |
| `FND-DB-001` | PostgreSQL platform bootstrap, roles, tenant isolation |
| `FND-DB-DOMAIN` | Core domain schema, event store, Alembic migrations |
| `FND-INFRA-001` | EKS, VPC, Terraform, Pod Identity |
| `FND-ART-001` | S3 and KMS artifact service |
| `FND-DEPLOY-001` | Helm, KEDA, autoscaling |
| `FND-OTEL-001` | OpenTelemetry and dashboard foundation |
| `FND-UI-001` | Control-plane UI and SSE shell |
| `FND-CICD-001` | CI/CD pipeline and release gates |
| `FND-DR-001` | Restore drill and Foundation acceptance exercise |

`FND-DB-DOMAIN` is registered as `blocked` with `SRC-001` in its blockers, which
is what makes the Defect 1 correction enforceable rather than merely detectable.

### Status accuracy

All ten are registered `planned` (or `blocked`) with `PENDING` gates.

`FND-REPO-001` and `FND-DB-001` have substantial delivered evidence already on
`main` from the Foundation baseline merge — repository structure and lockfiles,
the PostgreSQL 18 and pgvector bootstrap, three distinct `NOBYPASSRLS` roles,
the fail-closed workspace-context helper, and green integration CI asserting
that `SET LOCAL app.workspace_id` does not leak past `COMMIT`.

They are nevertheless registered `planned`. Marking a package `complete` is an
assertion by the work's author that every hard gate passes with evidence, and
that assertion is not this package's to make. Understating delivered work is a
recoverable reporting error; overstating it is exactly the failure mode the
control plane exists to prevent. Promoting them is a one-line status change once
their gate evidence is reviewed and attached.

The verifier rejected an initial draft of these records because four high-risk
packages had `approval_required: false`. That rule was not restated here from
memory; it was enforced by `verify` and the records were corrected.

## Regression proof

With the guard removed, the three new control-plane tests fail:

```
Ran 17 tests ... FAILED (failures=3)
```

With the guard in place, all pass:

```
Ran 17 tests ... OK
```

Applied to the live repository before the registry was completed, the guard
immediately caught the real defect:

```
$ python -m scripts.control_plane_policy verify
source gap SRC-001: blocks unknown work package 'FND-DB-DOMAIN'; ...
exit=1
```

This is why the two corrections ship together: the integrity check alone would
have turned CI red on `main`, because the dangling reference it detects was real.

## Gate evidence

### FND-CTRL2-G1 — dangling gap references rejected

- `scripts/control_plane_policy.py` — `policy_errors` blocks-reference validation
- `tests/control_plane/test_control_plane.py` —
  `test_source_gap_blocking_unknown_package_is_a_verification_error`,
  `test_resolved_source_gap_blocking_unknown_package_is_also_rejected`,
  `test_source_gap_blocks_entries_must_be_non_empty_strings`

### FND-CTRL2-G2 — complete Foundation registry

- `docs/implementation/work-packages/` — ten new records
- Control-plane report now lists twelve Foundation packages and a non-empty
  eligible-work listing

### FND-CTRL2-G3 — SRC-001 enforceable

- `docs/implementation/work-packages/FND-DB-DOMAIN.json` — `blocked`, blockers
  `["SRC-001"]`
- `strict_eligible_work_packages` excludes it while the gap is open

## Safety and rollback

No cloud resource, database, or workflow is touched; all state is
repository-local. Repository rollback is a Git revert, but reverting restores a
state in which `SRC-001` blocks nothing and the registry is incomplete, so a
revert should be paired with an alternative correction.
