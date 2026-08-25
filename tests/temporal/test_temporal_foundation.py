from __future__ import annotations

import ast
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TemporalFoundationContractTests(unittest.TestCase):
    def test_temporal_runtime_files_exist(self) -> None:
        required = [
            ROOT / "services" / "orchestrator" / "temporal" / "contracts.py",
            ROOT / "services" / "orchestrator" / "temporal" / "policies.py",
            ROOT / "services" / "orchestrator" / "temporal" / "workflows.py",
            ROOT / "services" / "orchestrator" / "temporal" / "activities.py",
            ROOT / "services" / "orchestrator" / "temporal" / "worker.py",
        ]
        missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
        self.assertEqual(missing, [])

    def test_workflow_module_has_no_direct_nondeterministic_io_imports(self) -> None:
        forbidden = {
            "asyncio",
            "requests",
            "httpx",
            "socket",
            "subprocess",
            "random",
            "time",
            "datetime",
            "os",
            "pathlib",
            "boto3",
            "sqlalchemy",
            "psycopg",
            "asyncpg",
        }
        paths = [
            ROOT / "services" / "orchestrator" / "temporal" / "workflows.py",
            ROOT / "services" / "orchestrator" / "temporal" / "runtime.py",
        ]
        for path in paths:
            with self.subTest(path=path.relative_to(ROOT)):
                tree = ast.parse(path.read_text(encoding="utf-8"))
                imported: set[str] = set()
                for node in ast.walk(tree):
                    if isinstance(node, ast.Import):
                        imported.update(
                            alias.name.split(".")[0] for alias in node.names
                        )
                    elif isinstance(node, ast.ImportFrom) and node.module:
                        root_module = node.module.split(".")[0]
                        if root_module != "datetime" or any(
                            alias.name != "timedelta" for alias in node.names
                        ):
                            imported.add(root_module)
                self.assertEqual(sorted(imported & forbidden), [])

    def test_policy_module_encodes_required_foundation_controls(self) -> None:
        from services.orchestrator.temporal.policies import (
            ACTIVITY_POLICIES,
            CONTINUE_AS_NEW,
            PRIORITIES,
            TASK_QUEUES,
            WORKER_VERSIONING,
        )

        self.assertIn("continuum.interactive", TASK_QUEUES)
        self.assertIn("continuum.background", TASK_QUEUES)
        self.assertIn("continuum.evaluation", TASK_QUEUES)
        self.assertIn("continuum.mutation", TASK_QUEUES)
        self.assertGreater(PRIORITIES["interactive"], PRIORITIES["background"])
        self.assertIn("model_call", ACTIVITY_POLICIES)
        self.assertGreaterEqual(ACTIVITY_POLICIES["model_call"].maximum_attempts, 1)
        self.assertIsNotNone(ACTIVITY_POLICIES["long_running"].heartbeat_timeout_seconds)
        self.assertEqual(CONTINUE_AS_NEW.max_events, 8_000)
        self.assertEqual(CONTINUE_AS_NEW.max_age_seconds, 24 * 3600)
        self.assertFalse(WORKER_VERSIONING.preview_only_required)
        self.assertTrue(WORKER_VERSIONING.rollback_supported)

    def test_activity_context_has_idempotency_and_trace_fields(self) -> None:
        from services.orchestrator.temporal.contracts import ActivityContext

        names = set(ActivityContext.__dataclass_fields__)
        self.assertTrue(
            {
                "workspace_id",
                "run_id",
                "task_id",
                "activity_id",
                "attempt",
                "idempotency_key",
                "traceparent",
            }.issubset(names)
        )

    def test_workflow_contract_exposes_continue_as_new_decision(self) -> None:
        from services.orchestrator.temporal.workflows import should_continue_as_new

        self.assertFalse(should_continue_as_new(event_count=1, age_seconds=1))
        self.assertTrue(should_continue_as_new(event_count=8_000, age_seconds=1))
        self.assertTrue(should_continue_as_new(event_count=1, age_seconds=24 * 3600))


if __name__ == "__main__":
    unittest.main()
