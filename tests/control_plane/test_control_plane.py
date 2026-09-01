from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from scripts.control_plane import (
    eligible_work_packages,
    load_control_state,
    render_report,
    verify_repository,
)
from scripts.control_plane_policy import policy_errors, strict_eligible_work_packages

ROOT = Path(__file__).resolve().parents[2]


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _seed_minimal_repo(root: Path) -> None:
    _write_json(
        root / "docs/implementation/requirements.json",
        {
            "schema_version": 1,
            "requirements": [
                {
                    "id": "REQ-001",
                    "statement": "Foundation must pass before later phases activate.",
                    "level": "MUST",
                    "source": "test fixture",
                    "source_kind": "local-policy",
                    "status": "active",
                }
            ],
        },
    )
    _write_json(
        root / "docs/implementation/phases.json",
        {
            "schema_version": 1,
            "phases": [
                {
                    "id": "foundation",
                    "name": "Foundation",
                    "order": 1,
                    "status": "in_progress",
                    "predecessor": None,
                    "acceptance_gates": [],
                    "autonomous_capability_allowed": False,
                },
                {
                    "id": "reasoning",
                    "name": "Persistent Reasoning",
                    "order": 2,
                    "status": "planned",
                    "predecessor": "foundation",
                    "acceptance_gates": [],
                    "autonomous_capability_allowed": False,
                },
            ],
        },
    )
    _write_json(
        root / "docs/implementation/source-gaps.json",
        {"schema_version": 1, "source_gaps": []},
    )
    (root / "docs/implementation/work-packages").mkdir(parents=True, exist_ok=True)


def _package(
    package_id: str,
    *,
    phase: str = "foundation",
    status: str = "planned",
    dependencies: list[str] | None = None,
    blockers: list[str] | None = None,
    gates: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "id": package_id,
        "phase": phase,
        "title": package_id,
        "status": status,
        "risk": "low",
        "approval_required": False,
        "source_requirements": ["REQ-001"],
        "dependencies": dependencies or [],
        "acceptance_gates": gates or [],
        "blockers": blockers or [],
        "rollback": "revert commit",
    }


class RepositoryContractTests(unittest.TestCase):
    def test_repository_control_state_is_valid(self) -> None:
        errors = verify_repository(ROOT) + policy_errors(load_control_state(ROOT))
        self.assertEqual(errors, [], "\n".join(errors))

    def test_complete_package_requires_hard_gate_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            _write_json(
                root / "docs/implementation/work-packages/FND-001.json",
                _package(
                    "FND-001",
                    status="complete",
                    gates=[
                        {
                            "id": "FND-001-G1",
                            "description": "Must prove completion",
                            "hard": True,
                            "status": "PASS",
                            "evidence": [],
                        }
                    ],
                ),
            )
            errors = verify_repository(root)
            self.assertTrue(any("evidence" in error.lower() for error in errors), errors)

    def test_dependency_cycle_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            _write_json(
                root / "docs/implementation/work-packages/FND-A.json",
                _package("FND-A", dependencies=["FND-B"]),
            )
            _write_json(
                root / "docs/implementation/work-packages/FND-B.json",
                _package("FND-B", dependencies=["FND-A"]),
            )
            errors = verify_repository(root)
            self.assertTrue(any("cycle" in error.lower() for error in errors), errors)

    def test_next_lists_only_packages_with_complete_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            evidence = root / "docs/implementation/evidence/A.md"
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text("passed\n", encoding="utf-8")

            _write_json(
                root / "docs/implementation/work-packages/FND-A.json",
                _package(
                    "FND-A",
                    status="complete",
                    gates=[
                        {
                            "id": "FND-A-G1",
                            "description": "done",
                            "hard": True,
                            "status": "PASS",
                            "evidence": [{"path": "docs/implementation/evidence/A.md"}],
                        }
                    ],
                ),
            )
            _write_json(
                root / "docs/implementation/work-packages/FND-B.json",
                _package("FND-B", status="ready", dependencies=["FND-A"]),
            )
            _write_json(
                root / "docs/implementation/work-packages/FND-C.json",
                _package("FND-C", dependencies=["FND-B"]),
            )

            state = load_control_state(root)
            eligible = eligible_work_packages(state)
            self.assertEqual([item["id"] for item in eligible], ["FND-B"])

    def test_later_phase_cannot_activate_before_predecessor_acceptance(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            phases_path = root / "docs/implementation/phases.json"
            payload = json.loads(phases_path.read_text(encoding="utf-8"))
            payload["phases"][0]["status"] = "blocked"
            payload["phases"][1]["status"] = "in_progress"
            _write_json(phases_path, payload)
            errors = verify_repository(root)
            self.assertTrue(any("predecessor" in error.lower() for error in errors), errors)

    def test_core_phase_validation_rejects_skipped_immediate_predecessor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            phases_path = root / "docs/implementation/phases.json"
            payload = json.loads(phases_path.read_text(encoding="utf-8"))
            payload["phases"][0]["status"] = "accepted"
            payload["phases"].append(
                {
                    "id": "memory",
                    "name": "Memory",
                    "order": 3,
                    "status": "in_progress",
                    "predecessor": "foundation",
                    "acceptance_gates": [],
                    "autonomous_capability_allowed": False,
                }
            )
            _write_json(phases_path, payload)
            errors = verify_repository(root)
            self.assertTrue(
                any("immediate predecessor" in error.lower() for error in errors), errors
            )

    def test_complete_package_cannot_bypass_phase_activation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            evidence = root / "docs/implementation/evidence/A.md"
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text("passed\n", encoding="utf-8")
            _write_json(
                root / "docs/implementation/work-packages/RSN-001.json",
                _package(
                    "RSN-001",
                    phase="reasoning",
                    status="complete",
                    gates=[
                        {
                            "id": "RSN-001-G1",
                            "description": "done",
                            "hard": True,
                            "status": "PASS",
                            "evidence": [{"path": "docs/implementation/evidence/A.md"}],
                        }
                    ],
                ),
            )
            state = load_control_state(root)
            errors = policy_errors(state)
            self.assertTrue(any("inactive phase" in error.lower() for error in errors), errors)

    def test_open_source_gap_automatically_blocks_registered_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            _write_json(
                root / "docs/implementation/source-gaps.json",
                {
                    "schema_version": 1,
                    "source_gaps": [
                        {
                            "id": "SRC-TEST",
                            "description": "fixture gap",
                            "status": "open",
                            "severity": "high",
                            "blocks": ["FND-B"],
                            "tracking": "https://example.invalid/gap",
                        }
                    ],
                },
            )
            _write_json(
                root / "docs/implementation/work-packages/FND-B.json",
                _package("FND-B", status="ready"),
            )
            state = load_control_state(root)
            errors = policy_errors(state)
            self.assertTrue(any("source gap" in error.lower() for error in errors), errors)
            self.assertEqual(strict_eligible_work_packages(state), [])

    def test_source_gap_blocking_unknown_package_is_a_verification_error(self) -> None:
        # A gap naming a package that does not exist blocks nothing: the blocker
        # loop only visits registered packages, so the control is silently
        # inert. This must fail verification rather than pass quietly.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            _write_json(
                root / "docs/implementation/source-gaps.json",
                {
                    "schema_version": 1,
                    "source_gaps": [
                        {
                            "id": "SRC-TEST",
                            "description": "fixture gap",
                            "status": "open",
                            "severity": "high",
                            "blocks": ["FND-DOES-NOT-EXIST"],
                            "tracking": "https://example.invalid/gap",
                        }
                    ],
                },
            )
            state = load_control_state(root)
            errors = policy_errors(state)
            self.assertTrue(any("unknown work package" in error for error in errors), errors)
            self.assertTrue(any("FND-DOES-NOT-EXIST" in error for error in errors), errors)

    def test_resolved_source_gap_blocking_unknown_package_is_also_rejected(self) -> None:
        # Registry integrity does not depend on gap status; a dangling reference
        # left behind by a deleted or renamed package is still a dead control.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            _write_json(
                root / "docs/implementation/source-gaps.json",
                {
                    "schema_version": 1,
                    "source_gaps": [
                        {
                            "id": "SRC-TEST",
                            "description": "fixture gap",
                            "status": "resolved",
                            "severity": "low",
                            "blocks": ["FND-DELETED"],
                            "tracking": "https://example.invalid/gap",
                        }
                    ],
                },
            )
            errors = policy_errors(load_control_state(root))
            self.assertTrue(any("unknown work package" in error for error in errors), errors)

    def test_source_gap_blocks_entries_must_be_non_empty_strings(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            _write_json(
                root / "docs/implementation/source-gaps.json",
                {
                    "schema_version": 1,
                    "source_gaps": [
                        {
                            "id": "SRC-TEST",
                            "description": "fixture gap",
                            "status": "open",
                            "severity": "high",
                            "blocks": ["   "],
                            "tracking": "https://example.invalid/gap",
                        }
                    ],
                },
            )
            errors = policy_errors(load_control_state(root))
            self.assertTrue(any("non-empty strings" in error for error in errors), errors)

    def test_phase_chain_must_match_order(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            phases_path = root / "docs/implementation/phases.json"
            payload = json.loads(phases_path.read_text(encoding="utf-8"))
            payload["phases"][1]["predecessor"] = None
            _write_json(phases_path, payload)
            errors = policy_errors(load_control_state(root))
            self.assertTrue(any("predecessor chain" in error.lower() for error in errors), errors)

    def test_malformed_package_scalars_return_validation_errors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            malformed = _package("FND-B")
            malformed["phase"] = ["foundation"]
            malformed["title"] = None
            malformed["status"] = {"value": "planned"}
            malformed["risk"] = ["low"]
            malformed["source_requirements"] = [["REQ-001"]]
            _write_json(root / "docs/implementation/work-packages/FND-B.json", malformed)

            try:
                errors = verify_repository(root)
            except TypeError as exc:
                self.fail(f"verification raised TypeError for malformed scalar data: {exc}")

            joined = "\n".join(errors).lower()
            self.assertIn("phase must be a non-empty string", joined)
            self.assertIn("title must be a non-empty string", joined)
            self.assertIn("status must be a non-empty string", joined)
            self.assertIn("risk must be a non-empty string", joined)
            self.assertIn("source_requirements[0] must be a non-empty string", joined)

    def test_report_renders_validation_errors_for_package_missing_title(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            package = _package("FND-B")
            del package["title"]
            _write_json(root / "docs/implementation/work-packages/FND-B.json", package)
            errors = verify_repository(root)
            state = load_control_state(root)

            report = render_report(state, errors)

            self.assertIn("## Verification errors", report)
            self.assertIn("missing required field 'title'", report)

    def test_authoritative_commands_use_policy_module_invocation(self) -> None:
        template = (ROOT / ".github/pull_request_template.md").read_text(encoding="utf-8")
        evidence = (ROOT / "docs/implementation/evidence/FND-CTRL-001.md").read_text(
            encoding="utf-8"
        )

        self.assertIn("python -m scripts.control_plane_policy verify", template)
        self.assertNotIn("python scripts/control_plane.py verify", template)
        self.assertIn("python -m scripts.control_plane_policy verify", evidence)
        self.assertIn("python -m scripts.control_plane_policy next", evidence)
        self.assertNotIn("python scripts/control_plane_policy.py", evidence)

    def test_workflow_invokes_policy_cli_as_python_module(self) -> None:
        workflow = (ROOT / ".github/workflows/implementation-control-plane.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("python -m scripts.control_plane_policy verify", workflow)
        self.assertIn("python -m scripts.control_plane_policy report", workflow)

    def test_temporal_package_advances_after_control_plane_completion(self) -> None:
        state = load_control_state(ROOT)
        self.assertEqual(state.work_packages["FND-CTRL-001"]["status"], "complete")
        temporal = state.work_packages["FND-TEMP-001"]
        self.assertIn("FND-CTRL-001", temporal["dependencies"])
        eligible = {item["id"] for item in strict_eligible_work_packages(state)}
        if temporal["status"] in {"planned", "ready"}:
            self.assertIn("FND-TEMP-001", eligible)
        else:
            self.assertEqual(temporal["status"], "complete")
            self.assertNotIn("FND-TEMP-001", eligible)
            hard_gates = [gate for gate in temporal["acceptance_gates"] if gate["hard"]]
            self.assertGreaterEqual(len(hard_gates), 1)
            self.assertTrue(all(gate["status"] == "PASS" for gate in hard_gates))


if __name__ == "__main__":
    unittest.main()
