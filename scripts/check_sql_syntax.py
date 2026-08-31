"""Parse the derived core schema with the real PostgreSQL grammar.

Runs before the database container starts, so a syntax error fails in seconds
instead of after provisioning PostgreSQL. This exists because a lenient
third-party SQL parser accepted a malformed CREATE TABLE that the server
rejected: a comma had been appended after a trailing `-- comment`, placing it
inside the comment rather than after the column. Only a real grammar catches
that, so this uses libpg_query via pglast.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pglast

DEFAULT_TARGETS = (
    "docs/spec/continuum_v1.2_core_schema.derived.sql",
    "docs/spec/continuum_v1.2_core_schema.derived.verify.sql",
)


def check(path: Path) -> bool:
    sql = "\n".join(
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if not line.startswith("\\")  # psql meta-commands are not SQL
    )
    try:
        statements = pglast.parse_sql(sql)
    except pglast.parser.ParseError as exc:
        print(f"FAIL  {path}: {exc}")
        return False
    print(f"ok    {path} ({len(statements)} statements)")
    return True


def main(argv: list[str]) -> int:
    targets = argv[1:] or list(DEFAULT_TARGETS)
    root = Path(__file__).resolve().parents[1]
    results = [check(root / t if not Path(t).is_absolute() else Path(t)) for t in targets]
    if not all(results):
        print("\nPostgreSQL grammar validation failed.")
        return 1
    print("\nPostgreSQL grammar validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
