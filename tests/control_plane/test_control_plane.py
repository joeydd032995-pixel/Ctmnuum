from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from scripts.control_plane import eligible_work_packages, load_control_state, verify_repository

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


class RepositoryContractTests(unittest.TestCase):
    def test_repository_control_state_is_valid(self) -> None:
        errors = verify_repository(ROOT)
        self.assertEqual(errors, [], "\n".join(errors))

    def test_complete_package_requires_hard_gate_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            _write_json(
                root / "docs/implementation/work-packages/FND-001.json",
                {
                    "schema_version": 1,
                    "id": "FND-001",
                    "phase": "foundation",
                    "title": "Fixture",
                    "status": "complete",
                    "risk": "low",
                    "approval_required": False,
                    "source_requirements": ["REQ-001"],
                    "dependencies": [],
                    "acceptance_gates": [
                        {
                            "id": "FND-001-G1",
                            "description": "Must prove completion",
                            "hard": True,
                            "status": "PASS",
                            "evidence": [],
                        }
                    ],
                    "blockers": [],
                    "rollback": "revert commit",
                },
            )
            errors = verify_repository(root)
            self.assertTrue(any("evidence" in error.lower() for error in errors), errors)

    def test_dependency_cycle_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _seed_minimal_repo(root)
            for package_id, dependency in (("FND-A", "FND-B"), ("FND-B", "FND-A")):
                _write_json(
                    root / f"docs/implementation/work-packages/{package_id}.json",
                    {
                        "schema_version": 1,
                        "id": package_id,
                        "phase": "foundation",
                        "title": package_id,
                        "status": "planned",
                        "risk": "low",
                        "approval_required": False,
                        "source_requirements": ["REQ-001"],
                        "dependencies": [dependency],
                        "acceptance_gates": [],
                        "blockers": [],
                        "rollback": "revert commit",
                    },
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

            packages = [
                ("FND-A", "complete", []),
                ("FND-B", "ready", ["FND-A"]),
                ("FND-C", "planned", ["FND-B"]),
            ]
            for package_id, status, dependencies in packages:
                gates = []
                if status == "complete":
                    gates = [
                        {
                            "id": f"{package_id}-G1",
                            "description": "done",
                            "hard": True,
                            "status": "PASS",
                            "evidence": [{"path": "docs/implementation/evidence/A.md"}],
                        }
                    ]
                _write_json(
                    root / f"docs/implementation/work-packages/{package_id}.json",
                    {
                        "schema_version": 1,
                        "id": package_id,
                        "phase": "foundation",
                        "title": package_id,
                        "status": status,
                        "risk": "low",
                        "approval_required": False,
                        "source_requirements": ["REQ-001"],
                        "dependencies": dependencies,
                        "acceptance_gates": gates,
                        "blockers": [],
                        "rollback": "revert commit",
                    },
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

    def test_completed_control_plane_unlocks_temporal_foundation(self) -> None:
        state = load_control_state(ROOT)
        self.assertEqual(state.work_packages["FND-CTRL-001"]["status"], "complete")
        eligible = {item["id"] for item in eligible_work_packages(state)}
        self.assertIn("FND-TEMP-001", eligible)


if __name__ == "__main__":
    unittest.main()
