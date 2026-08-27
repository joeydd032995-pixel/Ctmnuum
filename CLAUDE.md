# Continuum — working conventions

Continuum is a persistent autonomous reasoning environment: seven hard-gated
phases, durable state outside the model. This file records how work is done in
this repository. It is deliberately short; the enforceable rules live in code.

## The one rule that is not negotiable

**Never present reconstructed behaviour as recovered specification text.**
`CONT-LOCAL-GOV-001`. The v1.2 machine-readable core artifact is unrecoverable,
so much of `docs/spec/` is a labelled reconstruction. Every declaration in it
carries exactly one provenance tag:

| Tag | Meaning |
|---|---|
| `[V12]` | Stated directly in the v1.2 report |
| `[V11]` | Carried from the v1.0/v1.1 predecessor |
| `[DERIVED]` | Inferred from a cited v1.2 invariant |
| `[DECISION]` | No source support; requires an ADR before use |

Tagging an invented column `[V12]` is the failure this rule exists to prevent,
and it has happened here more than once. If you add a declaration, tag it. If you
change what a declaration *means* — adding a bound, a constraint, a domain — the
tag changes too: keep the source tag for the base field and add `[DERIVED]` for
what you introduced.

## Verify by executing, not by reading

Every defect found in this repository so far was found by running something.
None were found by careful reading — including the ones a careful reader had
already reviewed.

- A `SECURITY DEFINER` function with a hardened `search_path` called `digest()`
  from `public`. Unreachable. The event store could not accept one row.
- `CHECK (stage <> 'promoted' OR digest ~ '...')` passed on `NULL`, because
  `NULL ~ pattern` is `NULL` and `CHECK` rejects only `FALSE`.
- A comment swallowed a comma, so four `CREATE TABLE`s were malformed —
  and `sqlglot` accepted the file. `pglast` reproduced PostgreSQL's exact error.
- RLS was asserted by reading `pg_class.relrowsecurity`. A policy of
  `USING (workspace_id = workspace_id)` isolates nothing and passed.

**A test that cannot fail is a defect.** Before adding an assertion, break the
thing it covers and watch it fail. If it still passes, the assertion is
decorative. Record which failure mode you reproduced.

## Python

Configured in `pyproject.toml`; run these before pushing.

```
ruff check .                                   # E, F, I, UP, B, SIM; line length 100
mypy .                                         # strict
python -m unittest discover -s tests/control_plane -p 'test_*.py'
python -m scripts.control_plane_policy verify   # governance gate
```

- Python 3.13. `temporalio` is pinned exactly; the version is part of the
  contract, not a floor.
- Prefer `@dataclass(frozen=True, slots=True)` for policy objects, and validate
  in `__post_init__` — an unreachable threshold should fail at construction, not
  at runtime.
- Name the unit. `max_age_seconds`, not `max_age`. A number whose unit lives
  only in a comment eventually gets used in the wrong one.

## SQL

Target is PostgreSQL 18 + pgvector. The schema is validated in CI against the
real image; there is no local Postgres 18 in the review sandbox.

```
python scripts/check_sql_syntax.py    # pglast: the real PostgreSQL grammar
```

Run it before every push that touches SQL. It fails in seconds, before a
container starts, and it catches what lenient parsers wave through.

- **`timestamptz`, never `timestamp`.** And when a timestamp is hashed or
  compared across sessions, render it explicitly in UTC — `jsonb_build_object`
  serialises `timestamptz` through the *session* `TimeZone`.
- **Composite tenant foreign keys.** `REFERENCES parent (workspace_id, id)`, not
  `(id)`. A single-column FK lets a child in workspace A reference a parent in
  workspace B while still satisfying its own RLS predicate.
- **Test RLS as `continuum_app`, never as a superuser.** Superusers bypass RLS
  entirely, `FORCE` included, so policies are never evaluated. Checking
  `relrowsecurity` proves a flag is on, not that isolation works.
- **A grant is not a policy.** RLS constrains *which* rows a role may touch; it
  does not grant the privilege to touch any. Both are required.
- Call the tenant helper through a scalar subquery —
  `(SELECT continuum.current_workspace_id())` — so a `STABLE` function is
  hoisted into a one-time InitPlan rather than re-evaluated per row.
- `ON DELETE SET NULL` without a column list nulls *every* referencing column.
  Name the column: `ON DELETE SET NULL (col)`.

## The implementation control plane

`docs/implementation/` is a machine-checked registry, not documentation.
`scripts/control_plane_policy.py verify` is authoritative and runs in CI.

- Work is scoped by a work package (`work-packages/*.json`) with hard gates.
- A gate is `PASS` only with evidence in `evidence/<ID>.md` — a path or a stable
  external reference, not a claim.
- `high` or `critical` risk requires `approval_required: true`.
- A source gap that blocks a package which does not exist enforces nothing; the
  verifier rejects dangling references.
- Describe what a gate *actually* provides. `approved_by` is a foreign key: it
  proves a user row exists, not that anyone approved.

## Git and pull requests

- Develop on the branch you were assigned; never push to `main`.
- `.github/pull_request_template.md` is a layout to fill in — work package ID,
  gate table with evidence, verification actually run, rollback, blockers.
- Attach CI evidence by quoting the assertions from the job log. A green check
  proves the job exited zero; it does not prove the assertions ran. They have
  failed to run here before, when the schema failed to apply first.
- Merge is a human gate. Claude does not merge.
