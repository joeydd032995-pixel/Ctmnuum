# ADR-0008: Versions are pinned by the package that first uses them

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-09-01
- **Related:** `FND-SPEC-002`; `FND-REPO-001` (lockfile baseline)
- **Closes:** `[DECISION]` 6 of the companion document — the version clause of `SRC-001`

## Context

§6.2 names six libraries v1.2 uses or discusses but never versions: `alembic`,
`pydantic`, `openai`, `opentelemetry-*`, `boto3` and `psycopg`. The library set
is `[V12]`; the versions are not stated anywhere.

Issue #2 requires that **every** missing version be ADR-approved before
`SRC-001` closes. The obvious reading — pin all six now — runs straight into
what §6.2 itself already says:

> Inventing version numbers here would be exactly the failure
> `CONT-LOCAL-GOV-001` prohibits. These must be pinned at implementation time
> and recorded in `uv.lock`, not asserted as recovered specification.

**None of the six is imported anywhere in the tree.** Pinning them today would
choose versions for code that does not exist, against no interface, with no test
able to exercise the choice — and they would be bumped before first use. That is
inventing detail and calling it settled, one level up from the schema.

## Decision

**The rule is what gets approved, not a table of guesses.**

### 1. The lockfiles are authoritative

`uv.lock` and `pnpm-lock.yaml` record every resolved version. No version is
authoritative anywhere else — not in prose, not in a table in this document, not
in `[tool.continuum]`.

### 2. A library is pinned by the work package that first imports it

| Library | Pinned by |
|---|---|
| `alembic`, `psycopg` | `FND-DB-DOMAIN` (migrations, driver) |
| `opentelemetry-*` | `FND-OTEL-001` |
| `boto3` | `FND-ART-001` (S3, KMS) |
| `pydantic` | the first package defining a typed contract that needs it |
| `openai` | the first package calling a model provider |

The obligation has an owner rather than drifting. A package that adds an import
without a pin is not complete.

### 3. No version is ever presented as recovered v1.2 text

Where a version appears in the companion document it is tagged
`[DECISION: ADR-0008]` — never `[V12]`. v1.2 states the library set; it states
no version of anything except what is already reproduced verbatim elsewhere.

### 4. `[tool.continuum]` records only contract versions

`temporalio` is there because CLAUDE.md records its version as part of the
contract rather than a floor. `verify_structure.py` already enforces that it
agrees with `pyproject.toml`, and fails if they drift.

## What is pinned today

| Scope | Pinned |
|---|---|
| runtime | `temporalio==1.31.0` |
| dev | `ruff==0.15.8`, `mypy==1.19.1`, `pglast==8.4` |
| bootstrap | `uv==0.8.17`, in the workflows |

`uv` is pinned outside the lockfile because it is the tool that resolves the
lockfile — the one dependency that cannot come from the lock it produces.

## Consequences, stated narrowly

**This closes the version clause of `SRC-001` by deciding how versions are
fixed, not by fixing all of them today.** That is a weaker claim than "every
version is decided", and it should not be read as the stronger one. What is
settled is that no version will ever be invented to satisfy a document, and that
each is owned by the package that can actually validate it.

If a reviewer holds that issue #2 requires literal values for all six now, this
ADR does not satisfy that reading and `SRC-001` should stay open. The choice
between those readings was made deliberately, and it is recorded here rather
than resolved silently.

## Verification

- `uv lock --check` — the lock agrees with `pyproject.toml`.
- `scripts/verify_structure.py` — `[tool.continuum]` agrees with the dependency
  pin, `.python-version` satisfies `requires-python`, and the package manager is
  pinned exactly. Each of those assertions has a recorded negative control.
- `.github/workflows/quality.yml` — `uv sync --locked` and
  `pnpm install --frozen-lockfile`; neither updates a lockfile, both fail if it
  disagrees. No `pip install <pkg>==<ver>` remains in any workflow.

## Provenance

The library set is `[V12]`. Every version, and this rule, is
`[DECISION: ADR-0008]`.
