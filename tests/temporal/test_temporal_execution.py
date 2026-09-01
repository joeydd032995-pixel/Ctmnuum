from __future__ import annotations

import asyncio
import unittest

from temporalio.client import WorkflowFailureError
from temporalio.exceptions import ApplicationError
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
        async with (
            await WorkflowEnvironment.start_time_skipping() as env,
            Worker(
                env.client,
                task_queue=FOUNDATION_TASK_QUEUE,
                workflows=[FoundationWorkflow],
                activities=[FoundationActivity.execute],
            ),
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

    async def test_invalid_request_fails_execution_without_workflow_task_retry_loop(
        self,
    ) -> None:
        async with (
            await WorkflowEnvironment.start_time_skipping() as env,
            Worker(
                env.client,
                task_queue=FOUNDATION_TASK_QUEUE,
                workflows=[FoundationWorkflow],
                activities=[FoundationActivity.execute],
            ),
        ):
            handle = await env.client.start_workflow(
                FoundationWorkflow.run,
                WorkflowRequest(
                    workspace_id="",
                    run_id="run-invalid",
                    task_id="task-invalid",
                    objective="reject invalid workflow input",
                ),
                id="fnd-temp-invalid-request",
                task_queue=FOUNDATION_TASK_QUEUE,
            )
            try:
                await asyncio.wait_for(handle.result(), timeout=1)
            except WorkflowFailureError as failure:
                cause = failure.cause
                if not isinstance(cause, ApplicationError):
                    self.fail(f"expected ApplicationError, got {type(cause).__name__}")
                self.assertEqual(cause.type, "continuum.validation")
                self.assertTrue(cause.non_retryable)
            except TimeoutError:
                self.fail("invalid input left the Workflow Task retrying")
            else:
                self.fail("invalid input unexpectedly completed")


if __name__ == "__main__":
    unittest.main()
