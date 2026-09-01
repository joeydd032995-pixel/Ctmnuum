from __future__ import annotations

import unittest
from datetime import timedelta

from temporalio import workflow
from temporalio.api.enums.v1 import EventType
from temporalio.common import RetryPolicy
from temporalio.testing import WorkflowEnvironment
from temporalio.worker import Replayer, Worker

from services.orchestrator.temporal.contracts import (
    ActivityContext,
    WorkflowRequest,
    WorkflowResult,
)
from services.orchestrator.temporal.policies import ACTIVITY_POLICIES
from services.orchestrator.temporal.runtime import (
    FOUNDATION_TASK_QUEUE,
    FoundationActivity,
    FoundationWorkflow,
)


@workflow.defn(name="continuum.foundation.workflow")
class LegacyFoundationWorkflow:
    """Pre-patch workflow retained only to prove replay compatibility."""

    @workflow.run
    async def run(self, request: WorkflowRequest) -> WorkflowResult:
        policy = ACTIVITY_POLICIES["tool_call"]
        context = ActivityContext(
            workspace_id=request.workspace_id,
            run_id=request.run_id,
            task_id=request.task_id,
            activity_id="foundation.execute",
            attempt=1,
            idempotency_key=(
                f"{request.workspace_id}:{request.run_id}:{request.task_id}:foundation.execute"
            ),
        )
        return await workflow.execute_activity(
            FoundationActivity.execute,
            args=[request, context],
            start_to_close_timeout=timedelta(seconds=policy.start_to_close_timeout_seconds),
            schedule_to_close_timeout=timedelta(seconds=policy.schedule_to_close_timeout_seconds),
            retry_policy=RetryPolicy(maximum_attempts=policy.maximum_attempts),
        )


def _request(run_id: str) -> WorkflowRequest:
    return WorkflowRequest(
        workspace_id="workspace-replay",
        run_id=run_id,
        task_id="task-replay",
        objective="prove deterministic history replay",
    )


class TemporalReplayTests(unittest.IsolatedAsyncioTestCase):
    async def test_current_history_records_patch_marker_and_replays(self) -> None:
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
                _request("run-current"),
                id="fnd-temp-current-history",
                task_queue=FOUNDATION_TASK_QUEUE,
            )
            await handle.result()
            history = await handle.fetch_history()

        marker_events = [
            event
            for event in history.events
            if event.event_type == EventType.EVENT_TYPE_MARKER_RECORDED
        ]
        self.assertGreaterEqual(len(marker_events), 1)
        replay = await Replayer(workflows=[FoundationWorkflow]).replay_workflow(history)
        self.assertIsNone(replay.replay_failure)

    async def test_current_workflow_replays_pre_patch_history(self) -> None:
        async with (
            await WorkflowEnvironment.start_time_skipping() as env,
            Worker(
                env.client,
                task_queue=FOUNDATION_TASK_QUEUE,
                workflows=[LegacyFoundationWorkflow],
                activities=[FoundationActivity.execute],
            ),
        ):
            handle = await env.client.start_workflow(
                LegacyFoundationWorkflow.run,
                _request("run-legacy"),
                id="fnd-temp-legacy-history",
                task_queue=FOUNDATION_TASK_QUEUE,
            )
            await handle.result()
            history = await handle.fetch_history()

        replay = await Replayer(workflows=[FoundationWorkflow]).replay_workflow(history)
        self.assertIsNone(replay.replay_failure)


if __name__ == "__main__":
    unittest.main()
