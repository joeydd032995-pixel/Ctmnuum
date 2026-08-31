# Evidence — FND-REPO-001

## Scope

Work package: `FND-REPO-001` — Monorepo, build tooling and lockfile baseline.

The repository skeleton already existed before this package: `apps/`,
`packages/`, `services/`, `turbo.json`, `pnpm-workspace.yaml`, both lockfiles,
`.python-version` and `.node-version`. What did not exist was any of the three
gates actually holding. This package makes them hold.

## What was wrong, measured rather than assumed

### `FND-REPO-G3` was entirely unmet, not partially

No workflow ran `ruff` or `mypy` at all. `implementation-control-plane.yml` and
`temporal-foundation.yml` ran unit tests; `foundation-structure.yml` ran the
structure script. Nothing formatted, linted or typechecked, so the "ahead of unit
tests" ordering the gate names had nothing to order.

`main` was also red on both:

| Check | On `main` | Detail |
|---|---:|---|
| `ruff check .` | 23 | 10 `E501`, 5 `SIM117`, 4 `I001`, 3 `SIM102`, 1 `F401` |
| `ruff format --check .` | 11 files | never adopted |
| `mypy .` | **20**, not 2 | see below |

**`mypy` was under-reporting by a factor of ten.** On `main` it printed two
errors and stopped — `Source file found twice under different module names` is
fatal, and mypy exits with *"errors prevented further checking"*. The two visible
errors were configuration; behind them sat 18 real strict-mode errors that no
one had seen. The count only became visible after the module-resolution problem
was fixed:

| File | Errors | Nature |
|---|---:|---|
| `tests/unit/test_database_bootstrap_contract.py` | 10 | `setUpClass` populates `cls.sql` / `cls.normalized` with no class-level annotation |
| `scripts/control_plane.py` | 3 | `Any \| None` used as a `dict` key; `gate_ids` annotated twice in one scope |
| `scripts/control_plane_policy.py` | 3 | same shape: `phase` and `gap` rebound from a loop variable to an Optional |
| `services/orchestrator/temporal/runtime.py` | 2 | `dict[str, object]` options defeat every `execute_activity` overload |
| `tests/temporal/test_temporal_execution.py` | 2 | `assertIsInstance` does not narrow for a type checker |

This is worth recording as a pattern rather than a one-off: **a checker that
aborts early reports a floor, not a total.** The same is true of the assertion
suites elsewhere in this repository — a run that stops at the first failure has
measured one defect, not all of them.

### `FND-REPO-G2` had two live violations

The gate requires CI to install "from the committed lockfiles rather than ad-hoc
version pins". Two workflows did precisely the prohibited thing:

- `temporal-foundation.yml` — `pip install temporalio==1.31.0`
- `derived-core-schema.yml` — `pip install pglast==8.4`

Both pins were *correct*; the defect is that they were a second place the
version could drift from `pyproject.toml`, and CLAUDE.md records the `temporalio`
version as part of the contract rather than a floor. Both now resolve from
`uv.lock`.

The Node half of the gate was unexercised — `pnpm-lock.yaml` was committed but no
workflow installed from it. The quality job now runs
`pnpm install --frozen-lockfile`, which fails rather than updating the lockfile.

### `FND-REPO-G1` verified existence, not agreement

`scripts/verify_structure.py` asserted that `.python-version`, `.node-version`
and both lockfiles *exist*. It would have passed with `.python-version` saying
`3.13` while `pyproject.toml` required `3.14`. `package.json` also pinned
`engines.node` but nothing pinned the package manager, so CI could resolve a
different pnpm than a contributor.

## What changed

1. **Toolchain is locked.** `ruff==0.15.8`, `mypy==1.19.1` and `pglast==8.4` are
   a `[dependency-groups] dev` set in `uv.lock`. The one version that cannot come
   from the lockfile is `uv` itself, which resolves it; that pin is explicit in
   each workflow with the reason stated inline.
2. **`quality.yml` is a reusable workflow**, called by both workflows that run
   unit tests, which declare `needs: quality`. The ordering the gate requires is
   enforced by the job dependency graph rather than by file order — a job that
   merely appears earlier still runs in parallel.
3. **23 lint findings and 20 type errors fixed**, and `ruff format` adopted
   across the tree (11 files) in its own commit so the mechanical diff stays
   separable from the substantive one.
4. **`verify_structure.py` now checks that the pins agree**, not just that they
   exist.

## The autofix that would have deleted a live re-export

`ruff --fix` wanted to remove `FOUNDATION_TASK_QUEUE` from
`services/orchestrator/temporal/runtime.py` as an unused import. It is not
unused: all three Temporal test modules import it **from `runtime`**, not from
`policies`, so the "fix" would have broken them at import time. Confirmed by
grep before accepting the fix. The import is now an explicit `__all__` entry,
which states the intent instead of relying on nobody running `--fix`.

This is the argument against running a formatter or fixer over a repository
without reading what it proposes.

## A rename that typechecked and was still wrong

Fixing `scripts/control_plane.py:392` meant renaming `phase_id` to
`package_phase_id`, because the package loop was reusing a name the *phase* loop
above had already bound as `str`. Renaming only the assignment left five later
uses still reading `phase_id` — which silently resolved to the last phase's id
rather than the package's.

`mypy` passed. `ruff` passed. All 17 control-plane tests passed. The validation
would have reported the wrong phase in every message and compared against the
wrong phase's status.

Caught by reading the diff, then confirmed by breaking the checks deliberately:

| Mutation | Verifier output |
|---|---|
| Package names a phase that does not exist | `work package FND-REPO-001: unknown phase 'not_a_real_phase'` |
| Package is `ready` while its phase is not `in_progress` | `work package FND-REPO-001: owning phase 'memory' must be in_progress before status 'ready'` |

Both name the *package's* phase, which is what proves the rename landed
everywhere. Neither the type checker nor the existing tests could have told the
difference.

## Negative controls for the four new runtime-pin assertions

Each was broken and observed to fail before being trusted.

| Mutation | Result |
|---|---|
| *(none — baseline)* | `structure and runtime pins are consistent` |
| `.python-version` → `3.14.0` | `.python-version '3.14.0' does not match [tool.continuum].python '3.13'` |
| `.node-version` → `20.11.0` | `.node-version '20.11.0' does not match the engines.node lower bound '22.16.0'` |
| `packageManager` → `pnpm@latest` | `package.json packageManager 'pnpm@latest' is not an exact pnpm pin` |
| `[tool.continuum].temporalio` → `1.30.0` | `dependency 'temporalio==1.31.0' does not match [tool.continuum].temporalio '1.30.0'` |

## Gate evidence

### FND-REPO-G1 — structure and pinned runtimes verified

`scripts/verify_structure.py`, run by `.github/workflows/foundation-structure.yml`
and again inside `quality.yml`. Existence checks unchanged; `_runtime_pin_errors()`
added, with the four negative controls above.

### FND-REPO-G2 — lockfile-driven, reproducible resolution

`uv sync --locked` in every workflow that needs Python packages;
`pnpm install --frozen-lockfile` for Node. No `pip install <pkg>==<ver>` remains
in `.github/workflows/`. `uv lock --check` is clean.

### FND-REPO-G3 — format, lint, typecheck ahead of unit tests

`.github/workflows/quality.yml`, called with `needs:` by
`implementation-control-plane.yml` and `temporal-foundation.yml`.

## Local verification

Sandbox is Python 3.11 by default with `temporalio` installed globally under it,
which is why `mypy` could not resolve `temporalio` until the checks moved inside
the locked 3.13 environment. All commands below run through `uv run`.

```
uv run python scripts/verify_structure.py   structure and runtime pins are consistent
uv run ruff format --check .                19 files already formatted
uv run ruff check .                         All checks passed!
uv run mypy .                               Success: no issues found in 19 source files
uv run python -m unittest ... control_plane OK (17 tests)
uv run python -m unittest ... tests/unit    OK (6 tests)
uv run python -m scripts.control_plane_policy verify   PASS
uv run python scripts/check_sql_syntax.py   PostgreSQL grammar validation passed
uv lock --check                             in sync
```

**Five Temporal tests do not run in this sandbox.** They start a Temporal test
server downloaded from `temporal.download`, which is unreachable here. Confirmed
pre-existing by stashing all changes and re-running: 5 errors on unmodified
`main`, identical. They pass in CI, where the download succeeds. The `SIM117`
`with`-statement collapses in those files are therefore verified by CI rather
than locally; they are formatter-class changes that cannot alter semantics, and
`async with A as env, Worker(env.client, ...)` binds `env` before the second
context manager is evaluated.

## Review round: three findings, all confirmed

### The G3 claim was overstated, and the gate was partial

`FND-REPO-G3` reads *"format, lint and typecheck run in CI **ahead of unit
tests**"*. I wired `needs: quality` into two workflows and marked the gate
`PASS`. Audited across every workflow afterwards:

| Workflow | Runs unit tests | Gated (before) |
|---|---|---|
| `implementation-control-plane.yml` | yes | yes |
| `temporal-foundation.yml` | yes | yes |
| **`foundation-db-bootstrap.yml`** | **yes** | **no** |
| `derived-core-schema.yml`, `foundation-db-integration.yml`, `foundation-structure.yml` | no | n/a |

`foundation-db-bootstrap.yml` ran `python -m unittest
tests.unit.test_database_bootstrap_contract` with neither a `needs:` nor a call
to `quality.yml`, so on a pull request it raced the quality job. The gate held
for two of three test workflows.

This is worth recording as a governance failure rather than a CI one. The status
of a hard gate is the thing this control plane exists to make trustworthy; a
`PASS` that holds for most of the surface is the same class of error as an
assertion that passes on a schema it was written to reject.

Now gated, and moved onto `uv sync --locked` — the test imports only the
standard library, so bare `python` happened to work, which is luck rather than
design.

### Gating the job silently disabled the always-run reporting

`verify-control-plane` carried three steps with `if: always()` — generate
report, upload report, publish the PR status comment. The `always()` is
deliberate: those outputs must appear **when verification fails**, which is
exactly when someone needs to read them.

Adding `needs: quality` inverted that. GitHub **skips** a job whose dependency
failed, and a skipped job never evaluates step-level conditions. So a
formatting, lint or typecheck failure would have suppressed the report designed
to survive failure.

No test and no CI run could have caught this: every run had quality passing, so
the skip path never executed. It is visible only by reading the interaction
between a job-level `needs:` and a step-level `always()`.

Reporting is now its own job, `publish-control-plane-status`, with
`needs: [quality, verify-control-plane]` and **`if: always()` at job level** —
which runs regardless of what its dependencies did.

**This is not verified by a green CI run**, and the PR says so. Confirming it
requires a red quality job in real CI. What is verified is structural — parsing
every workflow and asserting that no test job is ungated and no reporting job
sits behind an unconditional gate:

```
workflow                           job                            tests  needs                        if
foundation-db-bootstrap.yml        database-bootstrap-contract    True   quality                      -
implementation-control-plane.yml   verify-control-plane           True   quality                      -
implementation-control-plane.yml   publish-control-plane-status   False  quality,verify-control-plane always()
temporal-foundation.yml            temporal-contracts             True   quality                      -
```

A permanent version of that check would make the gate self-enforcing rather than
conventional, and belongs in `FND-CICD-001` rather than widening this package.

### The pin check ignored `requires-python`

`_runtime_pin_errors()` compared `.python-version` against the private
`[tool.continuum].python` only. `[project].requires-python` — which actually
drives resolution — was never read, so raising it to `>=3.14,<3.15` while both
other values stayed at `3.13` passed the gate.

Now checked clause by clause. The design decision worth stating: the parser
**fails closed** on an operator it does not recognise, rather than skipping it.
Silently ignoring the unparseable case is how a check comes to pass on the
input it was written to reject — the third instance of that shape in this
package, after assertion 28 computing its expected value from the function under
test and assertion 33 testing membership instead of position.

One nuance found while testing: under `uv run`, uv itself refuses to start when
`.python-version` conflicts with `requires-python` (exit 2). But
`foundation-structure.yml` runs the script with **bare `python`**, where uv's
protection does not apply — which is the path this check actually covers. The
controls below therefore run under bare `python`, matching that workflow.

| Mutation | Result |
|---|---|
| *(none — baseline)* | `structure and runtime pins are consistent` |
| `requires-python` → `>=3.14,<3.15` | `.python-version '3.13.5' does not satisfy requires-python clause '>=3.14'` |
| `requires-python` → `>=3.13,<3.13` | `.python-version '3.13.5' does not satisfy requires-python clause '<3.13'` |
| `requires-python` → `^3.13` | `requires-python clause '^3.13' is not one this gate understands` |
| `requires-python` removed | `pyproject.toml [project] does not declare requires-python` |
| `.python-version` → `3.12.0` | `.python-version '3.12.0' does not match [tool.continuum].python '3.13'` |

## Safety and rollback

No production system, cloud resource or schema is touched. Rollback is a Git
revert; the only externally visible effect is CI configuration.
