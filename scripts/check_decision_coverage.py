"""Verify that every [DECISION] in the derived spec is covered by an ADR.

`CONT-LOCAL-GOV-001` turns on provenance tags meaning what they say. A
`[DECISION: ADR-0007]` naming an ADR that does not exist, or one still in draft,
reads as approved and is not -- and nothing else in the repository would notice.

Three failure modes, each of which has been reproduced:

1. a `[DECISION: ADR-nnnn]` reference whose ADR file is missing;
2. a referenced ADR that is not Accepted;
3. the companion document's enumeration drifting from the `[DECISION]` tags in
   the schema it claims to be generated from.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "docs" / "spec" / "continuum_v1.2_core_schema.derived.sql"
COMPANION = ROOT / "docs" / "spec" / "Continuum_v1.2_Core_Implementation_Artifact.derived.md"
ADR_DIR = ROOT / "docs" / "adr"

# Every file that may carry a [DECISION: ADR-nnnn] tag, relative to the root.
# Not just the spec: the Temporal policy module carries ADR-0007's tags, and a
# reference there is exactly as capable of naming a missing or unapproved ADR.
# Scanning only docs/spec/ left those unchecked -- found when the "not Accepted"
# branch failed to fire against an ADR referenced solely from Python.
TAGGED_SOURCES = (
    SCHEMA,
    COMPANION,
    ROOT / "docs" / "spec" / "continuum_v1.2_core_schema.derived.verify.sql",
    ROOT / "services" / "orchestrator" / "temporal" / "policies.py",
)

ADR_REFERENCE = re.compile(r"\[DECISION:\s*(ADR-(\d{4}))\]")
BARE_DECISION = re.compile(r"\[DECISION\](?!\s*:)")
ENUMERATION_ROW = re.compile(r"^\|\s*\d+\s*\|", re.M)


def _declaration_lines(schema_text: str) -> list[str]:
    """Lines where a bare [DECISION] annotates an actual declaration.

    The tag also appears on lines that declare nothing: the provenance legend at
    the top of the file, and prose comments explaining a choice. Counting those
    inflates the total and makes the enumeration look stale when it is correct.

    A declaration has SQL before the comment marker, so a line whose first
    non-space characters are `--` is commentary and does not count. Found by the
    check reporting drift on its first run, where the schema was right and this
    function was wrong.
    """

    return [
        line
        for line in schema_text.splitlines()
        if BARE_DECISION.search(line) and not line.lstrip().startswith("--")
    ]


def _adr_path(number: str) -> Path | None:
    matches = sorted(ADR_DIR.glob(f"{number}-*.md"))
    return matches[0] if matches else None


def coverage_errors() -> list[str]:
    errors: list[str] = []
    schema_text = SCHEMA.read_text(encoding="utf-8")
    companion_text = COMPANION.read_text(encoding="utf-8")

    # 1 and 2: every named ADR exists and is accepted.
    for path in TAGGED_SOURCES:
        source = path.name
        text = path.read_text(encoding="utf-8")
        for name, number in sorted(set(ADR_REFERENCE.findall(text))):
            adr = _adr_path(number)
            if adr is None:
                errors.append(f"{source}: [DECISION: {name}] names an ADR that does not exist")
                continue
            status_line = next(
                (
                    line
                    for line in adr.read_text(encoding="utf-8").splitlines()
                    if line.lstrip("- ").startswith("**Status:**")
                ),
                "",
            )
            if "Accepted" not in status_line:
                errors.append(
                    f"{source}: [DECISION: {name}] cites {adr.name}, which is not Accepted "
                    f"({status_line.strip() or 'no Status line'})"
                )

    # 3: the enumeration is claimed to be generated from the schema's tags.
    tagged = len(_declaration_lines(schema_text))
    enumerated = len(ENUMERATION_ROW.findall(companion_text))
    if tagged != enumerated:
        errors.append(
            f"the companion enumeration lists {enumerated} declaration(s) but the schema "
            f"carries {tagged} bare [DECISION] tag(s); the list claims to be generated "
            "from those tags, so it has drifted"
        )

    return errors


def main() -> int:
    errors = coverage_errors()
    if errors:
        print("Decision coverage failed:")
        for message in errors:
            print(f"  - {message}")
        return 1
    print("Every [DECISION] is covered by an accepted ADR, and the enumeration agrees.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
