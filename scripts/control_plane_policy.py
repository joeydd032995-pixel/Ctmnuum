from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from scripts.control_plane import (
    ControlState,
    eligible_work_packages,
    load_control_state,
    render_report,
    verify_repository,
)


def _open_gap_blocks(state: ControlState) -> dict[str, list[str]]:
    blocked: dict[str, list[str]] = {}
    for gap_id, gap in state.source_gaps.items():
        if gap.get("status") != "open":
            continue
        for package_id in gap.get("blocks", []):
            if isinstance(package_id, str):
                blocked.setdefault(package_id, []).append(gap_id)
    return blocked


def policy_errors(state: ControlState) -> list[str]:
    """Validate cross-registry governance rules that span core data structures."""

    errors: list[str] = []

    ordered_phases = sorted(state.phases.values(), key=lambda phase: phase.get("order", 0))
    expected_orders = list(range(1, len(ordered_phases) + 1))
    actual_orders = [phase.get("order") for phase in ordered_phases]
    if actual_orders != expected_orders:
        errors.append(
            "phase orders must be contiguous starting at 1: "
            f"expected {expected_orders}, got {actual_orders}"
        )

    for index, phase in enumerate(ordered_phases):
        expected_predecessor = None if index == 0 else ordered_phases[index - 1].get("id")
        if phase.get("predecessor") != expected_predecessor:
            errors.append(
                f"phase {phase.get('id')}: predecessor chain must follow phase order; "
                f"expected {expected_predecessor!r}, got {phase.get('predecessor')!r}"
            )

    # A source gap that names a work package which does not exist blocks
    # nothing: the blocker loop below only visits registered packages, so the
    # reference is silently inert and `verify` still passes. Treat a dangling
    # `blocks` entry as a verification error so a governance control cannot be
    # quietly disarmed by a typo or a deleted/renamed package.
    for gap_id, gap in sorted(state.source_gaps.items()):
        blocks = gap.get("blocks")
        if not isinstance(blocks, list):
            errors.append(f"source gap {gap_id}: blocks must be a list")
            continue
        for package_id in blocks:
            if not isinstance(package_id, str) or not package_id.strip():
                errors.append(f"source gap {gap_id}: blocks entries must be non-empty strings")
            elif package_id not in state.work_packages:
                errors.append(
                    f"source gap {gap_id}: blocks unknown work package "
                    f"'{package_id}'; a gap that blocks a package which does not "
                    "exist enforces nothing"
                )

    open_gap_blocks = _open_gap_blocks(state)

    for package_id, package in state.work_packages.items():
        package_phase_id = package.get("phase")
        package_phase = (
            state.phases.get(package_phase_id) if isinstance(package_phase_id, str) else None
        )
        status = package.get("status")

        if (
            status == "complete"
            and package_phase is not None
            and package_phase.get("status") not in {"in_progress", "accepted"}
        ):
            errors.append(
                f"work package {package_id}: complete package cannot bypass inactive phase "
                f"'{package_phase.get('id')}' with status '{package_phase.get('status')}'"
            )

        explicit_blockers = set(package.get("blockers", []))
        automatic_blockers = set(open_gap_blocks.get(package_id, []))

        missing_explicit = automatic_blockers - explicit_blockers
        if missing_explicit:
            errors.append(
                f"work package {package_id}: open source gap(s) "
                f"{', '.join(sorted(missing_explicit))} block this package "
                f"and must appear in blockers"
            )

        for blocker_id in explicit_blockers:
            blocker_gap = state.source_gaps.get(blocker_id)
            if blocker_gap is not None and blocker_gap.get("status") == "resolved":
                errors.append(
                    f"work package {package_id}: resolved source gap "
                    f"'{blocker_id}' remains in blockers"
                )

    return sorted(set(errors))


def strict_eligible_work_packages(state: ControlState) -> list[dict[str, Any]]:
    """Return core-eligible packages after applying source-gap governance."""

    open_gap_blocks = _open_gap_blocks(state)
    eligible = eligible_work_packages(state)
    return [package for package in eligible if package.get("id") not in open_gap_blocks]


def _state_with_effective_blockers(state: ControlState) -> ControlState:
    """Add open source-gap blockers in memory so core report rendering is conservative."""

    open_gap_blocks = _open_gap_blocks(state)
    for package_id, gap_ids in open_gap_blocks.items():
        package = state.work_packages.get(package_id)
        if package is None:
            continue
        existing = package.setdefault("blockers", [])
        for gap_id in gap_ids:
            if gap_id not in existing:
                existing.append(gap_id)
    return state


def verify_governance(root: Path) -> tuple[ControlState | None, list[str]]:
    core_errors = verify_repository(root)
    try:
        state = load_control_state(root)
    except ValueError as exc:
        load_errors = [line for line in str(exc).splitlines() if line]
        return None, sorted(set(core_errors + load_errors))

    return state, sorted(set(core_errors + policy_errors(state)))


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Continuum implementation governance policy layer")
    parser.add_argument("command", choices=("verify", "report", "next"))
    parser.add_argument("--root", type=Path, default=_repository_root())
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    state, errors = verify_governance(args.root)

    if state is None:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    if args.command == "verify":
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("Implementation control plane governance verification: PASS")
        return 0

    if args.command == "next":
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        for package in strict_eligible_work_packages(state):
            print(f"{package['id']}\t{package['title']}")
        return 0

    report_state = _state_with_effective_blockers(state)
    print(render_report(report_state, errors), end="")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
