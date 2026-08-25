from __future__ import annotations

import unittest

from temporalio import workflow
from temporalio.common import VersioningBehavior

from services.orchestrator.temporal import worker as deployment_module
from services.orchestrator.temporal.runtime import FoundationWorkflow


class WorkerVersioningTests(unittest.TestCase):
    def test_deployment_maps_to_stable_temporal_worker_versioning_config(self) -> None:
        deployment = deployment_module.build_worker_deployment(
            build_id="orchestrator-2026.08.25",
            rollback_build_id="orchestrator-2026.08.24",
        )
        config_factory = getattr(
            deployment_module, "build_temporal_deployment_config", None
        )
        self.assertIsNotNone(config_factory)
        if config_factory is None:
            return

        config = config_factory(deployment)
        self.assertTrue(config.use_worker_versioning)
        self.assertEqual(config.version.deployment_name, "continuum-orchestrator")
        self.assertEqual(config.version.build_id, "orchestrator-2026.08.25")
        self.assertEqual(
            config.default_versioning_behavior, VersioningBehavior.UNSPECIFIED
        )
        self.assertFalse(deployment.preview_features_enabled)

    def test_foundation_workflow_is_explicitly_pinned(self) -> None:
        definition = workflow._Definition.must_from_class(FoundationWorkflow)
        self.assertEqual(definition.versioning_behavior, VersioningBehavior.PINNED)

    def test_rollback_selects_previous_compatible_build(self) -> None:
        deployment = deployment_module.build_worker_deployment(
            build_id="orchestrator-2026.08.25",
            rollback_build_id="orchestrator-2026.08.24",
        )
        selector = getattr(deployment_module, "select_rollback_build", None)
        self.assertIsNotNone(selector)
        if selector is None:
            return

        self.assertEqual(selector(deployment), "orchestrator-2026.08.24")

    def test_rollback_rejects_deployment_without_previous_build(self) -> None:
        deployment = deployment_module.build_worker_deployment(
            build_id="orchestrator-2026.08.25"
        )
        selector = getattr(deployment_module, "select_rollback_build", None)
        self.assertIsNotNone(selector)
        if selector is None:
            return

        with self.assertRaisesRegex(ValueError, "rollback build is not configured"):
            selector(deployment)


if __name__ == "__main__":
    unittest.main()
