"""Verify that every [DECISION] in the derived spec is covered by an ADR.

`CONT-LOCAL-GOV-001` turns on provenance tags meaning what they say. A
`[DECISION: ADR-0007]` naming an ADR that does not exist, or one still in draft,
reads as approved and is not -- and nothing else in the repository would notice.

Five failure modes, each of which has been reproduced:

1. a `[DECISION: ADR-nnnn]` reference whose ADR file is missing;
2. a referenced ADR that is not Accepted;
3. a `[DECISION:` tag whose reference this file cannot parse -- rejected rather
   than skipped, because a skipped tag is an unchecked one;
4. the companion document's enumeration disagreeing with the `[DECISION]` tags in
   the schema it claims to be generated from -- compared declaration by
   declaration, not by total;
5. an enumeration row that cannot be parsed at all.
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

# The one accepted spelling of a qualified reference. Anything else that opens
# with `[DECISION:` is reported rather than ignored -- see _reference_errors.
ADR_REFERENCE = re.compile(r"\[DECISION:\s*(ADR-(\d{4}))\s*\]")
ANY_QUALIFIED_DECISION = re.compile(r"\[DECISION:[^\]]*\]")
BARE_DECISION = re.compile(r"\[DECISION\](?!\s*:)")

# `| 12 | `runs` | `created_by uuid REFERENCES continuum.users(id)` |`
ENUMERATION_ROW = re.compile(r"^\|\s*(\d+)\s*\|\s*`([^`]*)`\s*\|\s*`(.*)`\s*\|\s*$", re.M)
ENUMERATION_ROW_LOOSE = re.compile(r"^\|\s*\d+\s*\|.*$", re.M)

CREATE_TABLE = re.compile(r"CREATE TABLE (?:IF NOT EXISTS )?continuum\.(\w+)", re.I)
SCHEMA_LEVEL = "schema-level"

# The status value a reference must carry. Matched at the start of the value, so
# "Accepted for Foundation implementation" qualifies and "Not Accepted",
# "Superseded (was Accepted)" and "Proposed" do not. A substring test admitted
# every one of those.
ACCEPTED_PREFIX = "Accepted"


def _normalise(declaration: str) -> str:
    """Collapse whitespace and drop the trailing comma of a column definition.

    The companion aligns its columns for reading and the schema aligns them for
    a different width, so the two texts differ in whitespace while naming the
    same declaration. Nothing else is normalised: a changed type, constraint or
    default must still register as a difference.
    """

    return re.sub(r"\s+", " ", declaration).strip().rstrip(",").strip()


def schema_declarations(schema_text: str) -> list[tuple[str, str]]:
    """The (location, declaration) pairs a bare [DECISION] annotates, in order.

    The tag also appears on lines that declare nothing: the provenance legend at
    the top of the file, and prose comments explaining a choice. Counting those
    inflates the total and makes the enumeration look stale when it is correct.

    A declaration has SQL before the comment marker, so a line whose first
    non-space characters are `--` is commentary and does not count. Found by the
    check reporting drift on its first run, where the schema was right and this
    function was wrong.
    """

    location = SCHEMA_LEVEL
    declarations: list[tuple[str, str]] = []
    for line in schema_text.splitlines():
        table = CREATE_TABLE.search(line)
        if table:
            location = table.group(1)
        if BARE_DECISION.search(line) and not line.lstrip().startswith("--"):
            declarations.append((location, _normalise(line.split("--")[0])))
    return declarations


def companion_declarations(companion_text: str) -> list[tuple[str, str]]:
    return [
        (match.group(2), _normalise(match.group(3)))
        for match in ENUMERATION_ROW.finditer(companion_text)
    ]


def _adr_path(number: str) -> Path | None:
    matches = sorted(ADR_DIR.glob(f"{number}-*.md"))
    return matches[0] if matches else None


def _status_value(adr: Path) -> str:
    for line in adr.read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip("- ")
        if stripped.startswith("**Status:**"):
            return stripped.removeprefix("**Status:**").strip()
    return ""


def _reference_errors() -> list[str]:
    """Failure modes 1, 2 and 3: every named ADR exists, parses and is accepted."""

    errors: list[str] = []
    for path in TAGGED_SOURCES:
        source = path.name
        text = path.read_text(encoding="utf-8")

        # Fail closed on a reference this file cannot parse. `[DECISION:
        # ADR-0004 bound]` was in the committed schema and matched neither
        # pattern, so it was checked by nothing: not validated as a reference,
        # not counted as a declaration. Silently skipping the shape you did not
        # anticipate is how a gate ends up green on what it exists to reject.
        for tag in ANY_QUALIFIED_DECISION.findall(text):
            if not ADR_REFERENCE.fullmatch(tag):
                errors.append(
                    f"{source}: {tag} is not a reference this gate understands; write "
                    f"[DECISION: ADR-nnnn] and put any qualifier after the bracket"
                )

        for name, number in sorted(set(ADR_REFERENCE.findall(text))):
            adr = _adr_path(number)
            if adr is None:
                errors.append(f"{source}: [DECISION: {name}] names an ADR that does not exist")
                continue
            status = _status_value(adr)
            if not status.startswith(ACCEPTED_PREFIX):
                errors.append(
                    f"{source}: [DECISION: {name}] cites {adr.name}, which is not Accepted "
                    f"({status or 'no Status line'})"
                )
    return errors


def _enumeration_errors(schema_text: str, companion_text: str) -> list[str]:
    """Failure modes 4 and 5: the enumeration names what the schema tags.

    Comparing totals only would pass a row that names a different declaration,
    or a tag moved from one column to another -- the companion would then
    document something the executable schema does not mark, while the gate
    stayed green and ADR-0010's claim that the list cannot drift stayed false.
    """

    errors: list[str] = []
    tagged = schema_declarations(schema_text)
    enumerated = companion_declarations(companion_text)

    parsed = len(ENUMERATION_ROW_LOOSE.findall(companion_text))
    if parsed != len(enumerated):
        errors.append(
            f"{parsed - len(enumerated)} enumeration row(s) do not parse as "
            "`| n | `location` | `declaration` |`; an unparsed row is an unchecked one"
        )

    if len(tagged) != len(enumerated):
        errors.append(
            f"the companion enumeration lists {len(enumerated)} declaration(s) but the "
            f"schema carries {len(tagged)} bare [DECISION] tag(s); the list claims to be "
            "generated from those tags, so it has drifted"
        )

    for index, (want, got) in enumerate(zip(tagged, enumerated, strict=False), start=1):
        if want != got:
            errors.append(
                f"enumeration row {index} names {got[0]}.{got[1]!r} but the schema tags "
                f"{want[0]}.{want[1]!r} in that position"
            )
    return errors


def coverage_errors() -> list[str]:
    return _reference_errors() + _enumeration_errors(
        SCHEMA.read_text(encoding="utf-8"),
        COMPANION.read_text(encoding="utf-8"),
    )


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
