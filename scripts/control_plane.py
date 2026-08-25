from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

REQUIREMENT_LEVELS = {"MUST", "SHOULD", "MAY"}
REQUIREMENT_SOURCE_KINDS = {"v1.2", "adr", "local-policy"}
REQUIREMENT_STATUSES = {"active", "superseded"}
PHASE_STATUSES = {"planned", "in_progress", "blocked", "accepted"}
WORK_PACKAGE_STATUSES = {"planned", "ready", "in_progress", "blocked", "complete"}
RISKS = {"low", "medium", "high", "critical"}
GATE_STATUSES = {"PENDING", "PASS", "FAIL", "WAIVED"}
SOURCE_GAP_STATUSES = {"open", "resolved"}
SOURCE_GAP_SEVERITIES = {"low", "medium", "high", "critical"}


@dataclass(frozen=True)
class ControlState:
    root: Path
    requirements: dict[str, dict[str, Any]]
    phases: dict[str, dict[str, Any]]
    source_gaps: dict[str, dict[str, Any]]
    work_packages: dict[str, dict[str, Any]]


def _read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _require_keys(
    item: dict[str, Any], keys: tuple[str, ...], label: str, errors: list[str]
) -> None:
    for key in keys:
        if key not in item:
            errors.append(f"{label}: missing required field '{key}'")


def _index_by_id(
    items: list[Any], label: str, errors: list[str]
) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            errors.append(f"{label}[{index}]: expected object")
            continue
        identifier = item.get("id")
        if not isinstance(identifier, str) or not identifier.strip():
            errors.append(f"{label}[{index}]: missing/invalid id")
            continue
        if identifier in indexed:
            errors.append(f"{label}: duplicate id '{identifier}'")
            continue
        indexed[identifier] = item
    return indexed


def _load_document(path: Path, collection_key: str, errors: list[str]) -> list[Any]:
    if not path.is_file():
        errors.append(f"missing control-plane file: {path}")
        return []
    try:
        payload = _read_json(path)
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"{path}: invalid JSON: {exc}")
        return []
    if not isinstance(payload, dict):
        errors.append(f"{path}: root must be an object")
        return []
    if payload.get("schema_version") != 1:
        errors.append(f"{path}: schema_version must equal 1")
    collection = payload.get(collection_key)
    if not isinstance(collection, list):
        errors.append(f"{path}: '{collection_key}' must be a list")
        return []
    return collection


def load_control_state(root: Path) -> ControlState:
    root = root.resolve()
    errors: list[str] = []
    requirements_items = _load_document(
        root / "docs/implementation/requirements.json", "requirements", errors
    )
    phase_items = _load_document(
        root / "docs/implementation/phases.json", "phases", errors
    )
    gap_items = _load_document(
        root / "docs/implementation/source-gaps.json", "source_gaps", errors
    )

    work_package_dir = root / "docs/implementation/work-packages"
    work_package_items: list[Any] = []
    if not work_package_dir.is_dir():
        errors.append(f"missing work-package directory: {work_package_dir}")
    else:
        for path in sorted(work_package_dir.glob("*.json")):
            try:
                payload = _read_json(path)
            except (OSError, json.JSONDecodeError) as exc:
                errors.append(f"{path}: invalid JSON: {exc}")
                continue
            if not isinstance(payload, dict):
                errors.append(f"{path}: root must be an object")
                continue
            if payload.get("schema_version") != 1:
                errors.append(f"{path}: schema_version must equal 1")
            work_package_items.append(payload)

    requirements = _index_by_id(requirements_items, "requirements", errors)
    phases = _index_by_id(phase_items, "phases", errors)
    source_gaps = _index_by_id(gap_items, "source_gaps", errors)
    work_packages = _index_by_id(work_package_items, "work_packages", errors)

    if errors:
        raise ValueError("\n".join(errors))

    return ControlState(
        root=root,
        requirements=requirements,
        phases=phases,
        source_gaps=source_gaps,
        work_packages=work_packages,
    )


def _validate_evidence(
    evidence: Any,
    *,
    label: str,
    root: Path,
    required: bool,
    errors: list[str],
) -> None:
    if not isinstance(evidence, list):
        errors.append(f"{label}: evidence must be a list")
        return
    if required and not evidence:
        errors.append(f"{label}: passing hard gate requires evidence")
    for idx, item in enumerate(evidence):
        evidence_label = f"{label}.evidence[{idx}]"
        if not isinstance(item, dict):
            errors.append(f"{evidence_label}: expected object")
            continue
        path_value = item.get("path")
        external_ref = item.get("external_ref")
        if bool(path_value) == bool(external_ref):
            errors.append(
                f"{evidence_label}: provide exactly one of path or external_ref"
            )
            continue
        if path_value:
            if not isinstance(path_value, str) or not path_value.strip():
                errors.append(f"{evidence_label}: invalid path")
                continue
            evidence_path = (root / path_value).resolve()
            try:
                evidence_path.relative_to(root.resolve())
            except ValueError:
                errors.append(f"{evidence_label}: path escapes repository root")
                continue
            if not evidence_path.exists():
                errors.append(
                    f"{evidence_label}: evidence path does not exist: {path_value}"
                )
        elif not isinstance(external_ref, str) or not external_ref.strip():
            errors.append(f"{evidence_label}: invalid external_ref")


def _validate_gate(
    gate: Any,
    *,
    label: str,
    root: Path,
    errors: list[str],
    require_pass: bool,
) -> None:
    if not isinstance(gate, dict):
        errors.append(f"{label}: expected object")
        return
    _require_keys(
        gate, ("id", "description", "hard", "status", "evidence"), label, errors
    )
    hard = gate.get("hard")
    status = gate.get("status")
    if not isinstance(hard, bool):
        errors.append(f"{label}: hard must be boolean")
    if status not in GATE_STATUSES:
        errors.append(f"{label}: invalid status '{status}'")
        return
    if hard is True and status == "WAIVED":
        errors.append(f"{label}: hard gate cannot be WAIVED")
    if require_pass and hard is True and status != "PASS":
        errors.append(
            f"{label}: complete/accepted item requires hard gate PASS, got {status}"
        )
    _validate_evidence(
        gate.get("evidence"),
        label=label,
        root=root,
        required=(hard is True and status == "PASS"),
        errors=errors,
    )


def _dependency_cycles(packages: dict[str, dict[str, Any]]) -> list[str]:
    errors: list[str] = []
    state: dict[str, int] = {}
    stack: list[str] = []

    def visit(node: str) -> None:
        marker = state.get(node, 0)
        if marker == 2:
            return
        if marker == 1:
            if node in stack:
                start = stack.index(node)
                cycle = stack[start:] + [node]
            else:
                cycle = stack + [node]
            errors.append("dependency cycle detected: " + " -> ".join(cycle))
            return
        state[node] = 1
        stack.append(node)
        for dependency in packages[node].get("dependencies", []):
            if dependency in packages:
                visit(dependency)
        stack.pop()
        state[node] = 2

    for package_id in sorted(packages):
        if state.get(package_id, 0) == 0:
            visit(package_id)
    return errors


def verify_repository(root: Path) -> list[str]:
    root = root.resolve()
    try:
        state = load_control_state(root)
    except ValueError as exc:
        return [line for line in str(exc).splitlines() if line]

    errors: list[str] = []

    requirement_fields = ("id", "statement", "level", "source", "source_kind", "status")
    for requirement_id, requirement in state.requirements.items():
        label = f"requirement {requirement_id}"
        _require_keys(requirement, requirement_fields, label, errors)
        if requirement.get("level") not in REQUIREMENT_LEVELS:
            errors.append(f"{label}: invalid level '{requirement.get('level')}'")
        if requirement.get("source_kind") not in REQUIREMENT_SOURCE_KINDS:
            errors.append(
                f"{label}: invalid source_kind '{requirement.get('source_kind')}'"
            )
        if requirement.get("status") not in REQUIREMENT_STATUSES:
            errors.append(f"{label}: invalid status '{requirement.get('status')}'")

    phase_fields = (
        "id",
        "name",
        "order",
        "status",
        "predecessor",
        "acceptance_gates",
        "autonomous_capability_allowed",
    )
    phase_orders: dict[int, str] = {}
    in_progress: list[str] = []
    for phase_id, phase in state.phases.items():
        label = f"phase {phase_id}"
        _require_keys(phase, phase_fields, label, errors)
        order = phase.get("order")
        status = phase.get("status")
        predecessor = phase.get("predecessor")
        if not isinstance(order, int) or isinstance(order, bool) or order < 1:
            errors.append(f"{label}: order must be a positive integer")
        elif order in phase_orders:
            errors.append(
                f"{label}: duplicate order {order} also used by {phase_orders[order]}"
            )
        else:
            phase_orders[order] = phase_id
        if status not in PHASE_STATUSES:
            errors.append(f"{label}: invalid status '{status}'")
        if status == "in_progress":
            in_progress.append(phase_id)
        if predecessor is not None and predecessor not in state.phases:
            errors.append(f"{label}: unknown predecessor '{predecessor}'")
        if predecessor in state.phases and status in {"in_progress", "accepted"}:
            if state.phases[predecessor].get("status") != "accepted":
                errors.append(
                    f"{label}: predecessor '{predecessor}' must be accepted before status '{status}'"
                )
        gates = phase.get("acceptance_gates")
        if not isinstance(gates, list):
            errors.append(f"{label}: acceptance_gates must be a list")
        else:
            gate_ids: set[str] = set()
            for idx, gate in enumerate(gates):
                gate_label = f"{label}.acceptance_gates[{idx}]"
                _validate_gate(
                    gate,
                    label=gate_label,
                    root=root,
                    errors=errors,
                    require_pass=(status == "accepted"),
                )
                if isinstance(gate, dict):
                    gate_id = gate.get("id")
                    if isinstance(gate_id, str):
                        if gate_id in gate_ids:
                            errors.append(f"{label}: duplicate gate id '{gate_id}'")
                        gate_ids.add(gate_id)
        autonomous = phase.get("autonomous_capability_allowed")
        if not isinstance(autonomous, bool):
            errors.append(f"{label}: autonomous_capability_allowed must be boolean")
        elif autonomous:
            if phase_id != "evolution":
                errors.append(
                    f"{label}: autonomous capability may only be enabled in evolution"
                )
            if status != "accepted":
                errors.append(f"{label}: autonomous capability requires accepted phase")
            for other_id, other in state.phases.items():
                if (
                    other.get("order", 0) < phase.get("order", 0)
                    and other.get("status") != "accepted"
                ):
                    errors.append(
                        f"{label}: autonomous capability requires predecessor phase '{other_id}' accepted"
                    )
    if len(in_progress) > 1:
        errors.append(
            "only one phase may be in_progress: " + ", ".join(sorted(in_progress))
        )

    for phase_id, phase in state.phases.items():
        label = f"phase {phase_id}"
        order = phase.get("order")
        if not isinstance(order, int) or isinstance(order, bool) or order <= 1:
            continue
        expected_predecessor = phase_orders.get(order - 1)
        if expected_predecessor is None:
            errors.append(
                f"{label}: immediate predecessor order {order - 1} is missing"
            )
        elif phase.get("predecessor") != expected_predecessor:
            errors.append(
                f"{label}: immediate predecessor must be '{expected_predecessor}' "
                f"(order {order - 1})"
            )

    gap_fields = ("id", "description", "status", "severity", "blocks", "tracking")
    for gap_id, gap in state.source_gaps.items():
        label = f"source gap {gap_id}"
        _require_keys(gap, gap_fields, label, errors)
        if gap.get("status") not in SOURCE_GAP_STATUSES:
            errors.append(f"{label}: invalid status '{gap.get('status')}'")
        if gap.get("severity") not in SOURCE_GAP_SEVERITIES:
            errors.append(f"{label}: invalid severity '{gap.get('severity')}'")
        if not isinstance(gap.get("blocks"), list):
            errors.append(f"{label}: blocks must be a list")
        if not isinstance(gap.get("tracking"), str) or not gap.get("tracking", "").strip():
            errors.append(f"{label}: tracking must be a non-empty string")

    package_fields = (
        "id",
        "phase",
        "title",
        "status",
        "risk",
        "approval_required",
        "source_requirements",
        "dependencies",
        "acceptance_gates",
        "blockers",
        "rollback",
    )
    for package_id, package in state.work_packages.items():
        label = f"work package {package_id}"
        _require_keys(package, package_fields, label, errors)
        phase_id = package.get("phase")
        title = package.get("title")
        status = package.get("status")
        risk = package.get("risk")

        phase_is_string = isinstance(phase_id, str) and bool(phase_id.strip())
        if not phase_is_string:
            errors.append(f"{label}: phase must be a non-empty string")
        elif phase_id not in state.phases:
            errors.append(f"{label}: unknown phase '{phase_id}'")

        if not isinstance(title, str) or not title.strip():
            errors.append(f"{label}: title must be a non-empty string")

        status_is_string = isinstance(status, str) and bool(status.strip())
        if not status_is_string:
            errors.append(f"{label}: status must be a non-empty string")
        elif status not in WORK_PACKAGE_STATUSES:
            errors.append(f"{label}: invalid status '{status}'")

        risk_is_string = isinstance(risk, str) and bool(risk.strip())
        if not risk_is_string:
            errors.append(f"{label}: risk must be a non-empty string")
        elif risk not in RISKS:
            errors.append(f"{label}: invalid risk '{risk}'")

        approval_required = package.get("approval_required")
        if not isinstance(approval_required, bool):
            errors.append(f"{label}: approval_required must be boolean")
        elif risk_is_string and risk in {"high", "critical"} and not approval_required:
            errors.append(f"{label}: {risk} risk requires approval_required=true")

        requirements = package.get("source_requirements")
        if not isinstance(requirements, list) or not requirements:
            errors.append(f"{label}: source_requirements must be a non-empty list")
        else:
            for index, requirement_id in enumerate(requirements):
                if not isinstance(requirement_id, str) or not requirement_id.strip():
                    errors.append(
                        f"{label}: source_requirements[{index}] must be a non-empty string"
                    )
                    continue
                if requirement_id not in state.requirements:
                    errors.append(f"{label}: unknown requirement '{requirement_id}'")

        dependencies = package.get("dependencies")
        if not isinstance(dependencies, list):
            errors.append(f"{label}: dependencies must be a list")
            dependencies = []
        for dependency_id in dependencies:
            if dependency_id not in state.work_packages:
                errors.append(f"{label}: unknown dependency '{dependency_id}'")
            elif dependency_id == package_id:
                errors.append(f"{label}: package cannot depend on itself")

        blockers = package.get("blockers")
        if not isinstance(blockers, list):
            errors.append(f"{label}: blockers must be a list")
            blockers = []
        for blocker in blockers:
            if blocker not in state.source_gaps:
                errors.append(f"{label}: unknown blocker/source-gap '{blocker}'")
        if status_is_string and status == "complete" and blockers:
            errors.append(f"{label}: complete package cannot have blockers")

        if not isinstance(package.get("rollback"), str) or not package.get(
            "rollback", ""
        ).strip():
            errors.append(f"{label}: rollback must be a non-empty string")

        gates = package.get("acceptance_gates")
        if not isinstance(gates, list):
            errors.append(f"{label}: acceptance_gates must be a list")
        else:
            gate_ids: set[str] = set()
            for idx, gate in enumerate(gates):
                gate_label = f"{label}.acceptance_gates[{idx}]"
                _validate_gate(
                    gate,
                    label=gate_label,
                    root=root,
                    errors=errors,
                    require_pass=(status_is_string and status == "complete"),
                )
                if isinstance(gate, dict):
                    gate_id = gate.get("id")
                    if isinstance(gate_id, str):
                        if gate_id in gate_ids:
                            errors.append(f"{label}: duplicate gate id '{gate_id}'")
                        gate_ids.add(gate_id)

        if status_is_string and status in {"ready", "in_progress", "complete"}:
            for dependency_id in dependencies:
                dependency = state.work_packages.get(dependency_id)
                if dependency is not None and dependency.get("status") != "complete":
                    errors.append(
                        f"{label}: dependency '{dependency_id}' must be complete before status '{status}'"
                    )
        if (
            status_is_string
            and status in {"ready", "in_progress"}
            and phase_is_string
            and phase_id in state.phases
        ):
            if state.phases[phase_id].get("status") != "in_progress":
                errors.append(
                    f"{label}: owning phase '{phase_id}' must be in_progress before status '{status}'"
                )

    errors.extend(_dependency_cycles(state.work_packages))
    return sorted(set(errors))


def eligible_work_packages(state: ControlState) -> list[dict[str, Any]]:
    eligible: list[dict[str, Any]] = []
    for package in state.work_packages.values():
        if package.get("status") not in {"planned", "ready"}:
            continue
        phase = state.phases.get(package.get("phase"))
        if not phase or phase.get("status") != "in_progress":
            continue
        blockers = package.get("blockers", [])
        if blockers:
            continue
        dependencies = package.get("dependencies", [])
        if all(
            dependency in state.work_packages
            and state.work_packages[dependency].get("status") == "complete"
            for dependency in dependencies
        ):
            eligible.append(package)
    return sorted(eligible, key=lambda item: item["id"])


def _gate_summary(gates: Any) -> str:
    if not isinstance(gates, list) or not gates:
        return "—"
    counts: dict[str, int] = {}
    for gate in gates:
        if isinstance(gate, dict):
            status = str(gate.get("status", "?"))
            counts[status] = counts.get(status, 0) + 1
    return ", ".join(f"{key}:{counts[key]}" for key in sorted(counts))


def render_report(state: ControlState, errors: list[str]) -> str:
    in_progress = [
        phase for phase in state.phases.values() if phase.get("status") == "in_progress"
    ]
    current_phase = in_progress[0]["name"] if len(in_progress) == 1 else "None"

    lines = [
        "# Continuum Implementation Control Plane",
        "",
        f"**Current phase:** {current_phase}",
        f"**Verification:** {'PASS' if not errors else 'FAIL'}",
        "",
        "## Phases",
        "",
        "| Order | Phase | Status | Autonomous allowed |",
        "| ---: | --- | --- | --- |",
    ]
    for phase in sorted(state.phases.values(), key=lambda item: item.get("order", 0)):
        lines.append(
            f"| {phase.get('order')} | {phase.get('name')} | {phase.get('status')} | "
            f"{'yes' if phase.get('autonomous_capability_allowed') else 'no'} |"
        )

    lines.extend(
        [
            "",
            "## Work packages",
            "",
            "| ID | Phase | Status | Risk | Hard-gate state |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    for package in sorted(
        state.work_packages.values(), key=lambda item: item.get("id", "")
    ):
        lines.append(
            f"| {package.get('id')} | {package.get('phase')} | {package.get('status')} | "
            f"{package.get('risk')} | {_gate_summary(package.get('acceptance_gates'))} |"
        )

    eligible = eligible_work_packages(state)
    lines.extend(["", "## Next eligible work packages", ""])
    if eligible:
        for package in eligible:
            package_id = package.get("id")
            title = package.get("title")
            display_id = package_id if isinstance(package_id, str) and package_id else "<invalid id>"
            display_title = title if isinstance(title, str) and title.strip() else "<missing title>"
            lines.append(f"- `{display_id}` — {display_title}")
    else:
        lines.append("- None")

    open_gaps = [
        gap for gap in state.source_gaps.values() if gap.get("status") == "open"
    ]
    lines.extend(["", "## Open source gaps", ""])
    if open_gaps:
        for gap in sorted(open_gaps, key=lambda item: item["id"]):
            lines.append(
                f"- `{gap['id']}` ({gap['severity']}) — {gap['description']} "
                f"Tracking: {gap['tracking']}"
            )
    else:
        lines.append("- None")

    lines.extend(["", "## Verification errors", ""])
    if errors:
        for error in errors:
            lines.append(f"- {error}")
    else:
        lines.append("- None")

    lines.append("")
    return "\n".join(lines)


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Continuum implementation control plane")
    parser.add_argument(
        "command",
        choices=("verify", "report", "next"),
        help="operation to perform",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=_repository_root(),
        help="repository root (defaults to this checkout)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    errors = verify_repository(args.root)
    try:
        state = load_control_state(args.root)
    except ValueError as exc:
        if args.command == "report":
            print("# Continuum Implementation Control Plane\n")
            print("**Verification:** FAIL\n")
            print("## Verification errors\n")
            for line in str(exc).splitlines():
                if line:
                    print(f"- {line}")
        else:
            for line in str(exc).splitlines():
                if line:
                    print(line, file=sys.stderr)
        return 1

    if args.command == "verify":
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("Implementation control plane verification: PASS")
        return 0

    if args.command == "report":
        print(render_report(state, errors), end="")
        return 1 if errors else 0

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    for package in eligible_work_packages(state):
        print(f"{package['id']}\t{package['title']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
