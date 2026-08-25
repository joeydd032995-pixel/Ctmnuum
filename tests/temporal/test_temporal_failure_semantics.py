from __future__ import annotations

import unittest
from datetime import timedelta

from temporalio import workflow

from services.orchestrator.temporal import activities, runtime
from services.orchestrator.temporal.contracts import WorkflowRequest
from services.orchestrator.temporal.policies import ACTIVITY_POLICIES, CONTINUE_AS_NEW
from services.orchestrator.temporal.workflows import should_continue_as_new


def _request() -> WorkflowRequest:
    return WorkflowRequest(
        workspace_id="workspace-policy",
        run_id="run-policy",
        task_id="task-policy",
        objective="verify Temporal failure semantics",
    )


class TemporalFailureSemanticsTests(unittest.TestCase):
    def test_retry_policy_maps_attempts_and_permanent_errors_to_sdk(self) -> None:
        options_factory = getattr(runtime, "activity_execution_options", None)
        self.assertIsNotNone(options_factory)
        if options_factory is None:
            return

        options = options_factory("model_call")
        retry = options["retry_policy"]
        self.assertEqual(retry.maximum_attempts, 3)
        self.assertEqual(
            tuple(retry.non_retryable_error_types or ()),
            (
                "continuum.validation",
                "continuum.authorization",
                "continuum.policy_denied",
                "continuum.permanent",
            ),
        )

    def test_long_running_policy_maps_heartbeat_and_cancellation(self) -> None:
        options_factory = getattr(runtime, "activity_execution_options", None)
        self.assertIsNotNone(options_factory)
        if options_factory is None:
            return

        options = options_factory("long_running")
        self.assertEqual(options["heartbeat_timeout"], timedelta(seconds=30))
        self.assertEqual(
            options["cancellation_type"], workflow.ActivityCancellationType.TRY_CANCEL
        )
        self.assertEqual(options["retry_policy"].maximum_attempts, 2)

    def test_activity_context_uses_stable_idempotency_key(self) -> None:
        builder = getattr(activities, "build_activity_context", None)
        self.assertIsNotNone(builder)
        if builder is None:
            return

        first = builder(_request(), activity_context_version="v1")
        duplicate = builder(_request(), activity_context_version="v1")
        legacy = builder(_request(), activity_context_version=None)

        self.assertEqual(first.idempotency_key, duplicate.idempotency_key)
        self.assertEqual(
            first.idempotency_key,
            "workspace-policy:run-policy:task-policy:foundation.execute.v1",
        )
        self.assertNotEqual(first.idempotency_key, legacy.idempotency_key)

    def test_continue_as_new_thresholds_are_exact(self) -> None:
        self.assertFalse(
            should_continue_as_new(
                event_count=CONTINUE_AS_NEW.max_events - 1,
                age_seconds=CONTINUE_AS_NEW.max_age_seconds - 1,
            )
        )
        self.assertTrue(
            should_continue_as_new(
                event_count=CONTINUE_AS_NEW.max_events,
                age_seconds=0,
            )
        )
        self.assertTrue(
            should_continue_as_new(
                event_count=0,
                age_seconds=CONTINUE_AS_NEW.max_age_seconds,
            )
        )

    def test_long_running_policy_is_explicitly_cancellable(self) -> None:
        self.assertTrue(ACTIVITY_POLICIES["long_running"].cancellable)


if __name__ == "__main__":
    unittest.main()
