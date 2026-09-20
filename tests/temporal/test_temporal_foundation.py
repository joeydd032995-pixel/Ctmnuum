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
                        imported.update(alias.name.split(".")[0] for alias in node.names)
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

    def test_retry_policies_match_the_values_v12_states(self) -> None:
        """[V12] The four named policies, asserted against literal values.

        Written against literals rather than derived from RETRY_POLICIES: a test
        that reads its expectation from the thing under test cannot fail. This
        package has produced that defect before -- assertion 28 in the derived
        schema computed its expected dates by calling the function it was
        checking, and changing the schedule produced no failure.

        These need no Temporal server, so they run in the review sandbox rather
        than only in CI.
        """
        from services.orchestrator.temporal.policies import RETRY_POLICIES

        expected = {
            "MODEL_RETRY": (2, 2.0, 20, 3),
            "IO_RETRY": (1, 2.0, 30, 5),
            "SIDE_EFFECT_RETRY": (2, 2.0, 30, 3),
            "SANDBOX_RETRY": (5, 2.0, 30, 2),
        }
        self.assertEqual(sorted(RETRY_POLICIES), sorted(expected))

        for name, (initial, backoff, maximum, attempts) in expected.items():
            with self.subTest(policy=name):
                policy = RETRY_POLICIES[name]
                self.assertEqual(policy.initial_interval_seconds, initial)
                self.assertEqual(policy.backoff_coefficient, backoff)
                self.assertEqual(policy.maximum_interval_seconds, maximum)
                self.assertEqual(policy.maximum_attempts, attempts)

        # v1.2 names non-retryable types for two of the four, and leaves the
        # other two empty. An entry appearing on IO_RETRY or SANDBOX_RETRY would
        # be an addition to the specification, not a reproduction of it.
        self.assertEqual(
            RETRY_POLICIES["MODEL_RETRY"].non_retryable_error_types,
            (
                "InvalidInputError",
                "ProviderBadRequestError",
                "PolicyDeniedError",
                "BudgetExceededError",
            ),
        )
        self.assertEqual(
            RETRY_POLICIES["SIDE_EFFECT_RETRY"].non_retryable_error_types,
            (
                "PolicyDeniedError",
                "HumanApprovalRejected",
                "NonIdempotentActionError",
                "InvalidInputError",
            ),
        )
        self.assertEqual(RETRY_POLICIES["IO_RETRY"].non_retryable_error_types, ())
        self.assertEqual(RETRY_POLICIES["SANDBOX_RETRY"].non_retryable_error_types, ())

    def test_every_activity_class_names_a_v12_retry_policy(self) -> None:
        """[DERIVED: ADR-0007] The mapping, and that attempts read through it.

        v1.2 states the four policies and states the activity classes but never
        which governs which. The mapping is inferred, so it is asserted here
        rather than left implicit -- and the attempt counts are the ones v1.2
        states for the mapped policy, not the ones the classes carried before.
        """
        from services.orchestrator.temporal.policies import ACTIVITY_POLICIES

        expected_mapping = {
            "model_call": ("MODEL_RETRY", 3),
            "retrieval": ("IO_RETRY", 5),
            "tool_call": ("SIDE_EFFECT_RETRY", 3),
            "long_running": ("SANDBOX_RETRY", 2),
        }
        self.assertEqual(sorted(ACTIVITY_POLICIES), sorted(expected_mapping))

        for activity_class, (policy_name, attempts) in expected_mapping.items():
            with self.subTest(activity_class=activity_class):
                policy = ACTIVITY_POLICIES[activity_class]
                self.assertEqual(policy.retry_policy, policy_name)
                self.assertEqual(policy.maximum_attempts, attempts)
                # Continuum's permanent types survive the union in every class.
                self.assertIn("continuum.policy_denied", policy.non_retryable_error_types)

    def test_activity_policy_rejects_an_unknown_retry_policy(self) -> None:
        from services.orchestrator.temporal.policies import ActivityPolicy

        with self.assertRaises(ValueError) as caught:
            ActivityPolicy(
                retry_policy="NO_SUCH_RETRY",
                start_to_close_timeout_seconds=10,
                schedule_to_close_timeout_seconds=20,
            )
        self.assertIn("NO_SUCH_RETRY", str(caught.exception))

    def test_activity_policy_rejects_a_deadline_shorter_than_one_attempt(self) -> None:
        """A schedule_to_close below start_to_close cannot fit one attempt."""
        from services.orchestrator.temporal.policies import ActivityPolicy

        with self.assertRaises(ValueError):
            ActivityPolicy(
                retry_policy="IO_RETRY",
                start_to_close_timeout_seconds=300,
                schedule_to_close_timeout_seconds=120,
            )

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
        self.assertTrue(should_continue_as_new(event_count=8_001, age_seconds=1))
        self.assertTrue(should_continue_as_new(event_count=1, age_seconds=24 * 3600 + 1))


if __name__ == "__main__":
    unittest.main()
