from __future__ import annotations

import unittest

from temporalio.testing import WorkflowEnvironment
from temporalio.worker import Worker

from services.orchestrator.temporal.contracts import WorkflowRequest
from services.orchestrator.temporal.runtime import (
    FOUNDATION_TASK_QUEUE,
    FoundationActivity,
    FoundationWorkflow,
)


class TemporalExecutionTests(unittest.IsolatedAsyncioTestCase):
    async def test_foundation_workflow_executes_through_temporal_worker(self) -> None:
        async with await WorkflowEnvironment.start_time_skipping() as env:
            async with Worker(
                env.client,
                task_queue=FOUNDATION_TASK_QUEUE,
                workflows=[FoundationWorkflow],
                activities=[FoundationActivity.execute],
            ):
                request = WorkflowRequest(
                    workspace_id="workspace-1",
                    run_id="run-1",
                    task_id="task-1",
                    objective="verify durable execution boundary",
                )
                result = await env.client.execute_workflow(
                    FoundationWorkflow.run,
                    request,
                    id="fnd-temp-execution-test",
                    task_queue=FOUNDATION_TASK_QUEUE,
                )

        self.assertEqual(result.status, "completed")
        self.assertEqual(result.run_id, request.run_id)
        self.assertEqual(result.task_id, request.task_id)
        self.assertIn("workspace-1:run-1:task-1", result.artifact_ref)


if __name__ == "__main__":
    unittest.main()
