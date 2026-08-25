from __future__ import annotations

import importlib.util
import unittest


class TemporalRuntimeTests(unittest.TestCase):
    def test_temporal_sdk_dependency_is_available_in_ci(self) -> None:
        self.assertIsNotNone(importlib.util.find_spec("temporalio"))

    def test_sdk_workflow_and_activity_are_registered(self) -> None:
        from services.orchestrator.temporal.runtime import (
            FoundationActivity,
            FoundationWorkflow,
        )

        self.assertTrue(hasattr(FoundationWorkflow, "run"))
        self.assertTrue(callable(FoundationActivity.execute))


if __name__ == "__main__":
    unittest.main()
