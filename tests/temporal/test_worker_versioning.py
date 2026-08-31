from __future__ import annotations

import unittest

from temporalio import workflow
from temporalio.common import VersioningBehavior
from temporalio.testing import WorkflowEnvironment
from temporalio.worker import Worker

from services.orchestrator.temporal import worker as deployment_module
from services.orchestrator.temporal.contracts import WorkflowRequest
from services.orchestrator.temporal.runtime import (
    FOUNDATION_TASK_QUEUE,
    FoundationActivity,
    FoundationWorkflow,
)


class WorkerVersioningTests(unittest.IsolatedAsyncioTestCase):
    def test_deployment_maps_to_stable_temporal_worker_versioning_config(self) -> None:
        deployment = deployment_module.build_worker_deployment(
            build_id="orchestrator-2026.08.25",
            rollback_build_id="orchestrator-2026.08.24",
        )
        config_factory = getattr(deployment_module, "build_temporal_deployment_config", None)
        self.assertIsNotNone(config_factory)
        if config_factory is None:
            return

        config = config_factory(deployment)
        self.assertTrue(config.use_worker_versioning)
        self.assertEqual(config.version.deployment_name, "continuum-orchestrator")
        self.assertEqual(config.version.build_id, "orchestrator-2026.08.25")
        self.assertEqual(config.default_versioning_behavior, VersioningBehavior.UNSPECIFIED)
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
        deployment = deployment_module.build_worker_deployment(build_id="orchestrator-2026.08.25")
        selector = getattr(deployment_module, "select_rollback_build", None)
        self.assertIsNotNone(selector)
        if selector is None:
            return

        with self.assertRaisesRegex(ValueError, "rollback build is not configured"):
            selector(deployment)

    async def test_versioned_worker_covers_and_executes_foundation_queue(self) -> None:
        deployment = deployment_module.build_worker_deployment(build_id="orchestrator-2026.08.25")
        self.assertIn(FOUNDATION_TASK_QUEUE, deployment.task_queues)

        async with (
            await WorkflowEnvironment.start_time_skipping() as env,
            Worker(
                env.client,
                task_queue=FOUNDATION_TASK_QUEUE,
                workflows=[FoundationWorkflow],
                activities=[FoundationActivity.execute],
                deployment_config=deployment_module.build_temporal_deployment_config(deployment),
            ),
        ):
            result = await env.client.execute_workflow(
                FoundationWorkflow.run,
                WorkflowRequest(
                    workspace_id="workspace-versioned",
                    run_id="run-versioned",
                    task_id="task-versioned",
                    objective="verify versioned Foundation worker",
                ),
                id="fnd-temp-versioned-worker",
                task_queue=FOUNDATION_TASK_QUEUE,
            )

        self.assertEqual(result.status, "completed")


if __name__ == "__main__":
    unittest.main()
