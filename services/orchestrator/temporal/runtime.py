from __future__ import annotations

from datetime import timedelta

from temporalio import activity, workflow
from temporalio.common import RetryPolicy

from services.orchestrator.temporal.activities import execute_foundation_activity
from services.orchestrator.temporal.contracts import ActivityContext, WorkflowRequest, WorkflowResult
from services.orchestrator.temporal.policies import ACTIVITY_POLICIES
from services.orchestrator.temporal.workflows import validate_workflow_request


@activity.defn(name="continuum.foundation.execute")
async def _foundation_execute(
    request: WorkflowRequest,
    context: ActivityContext,
) -> WorkflowResult:
    return execute_foundation_activity(request=request, context=context)


class FoundationActivity:
    execute = staticmethod(_foundation_execute)


@workflow.defn(name="continuum.foundation.workflow")
class FoundationWorkflow:
    @workflow.run
    async def run(self, request: WorkflowRequest) -> WorkflowResult:
        validate_workflow_request(request)
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
        policy = ACTIVITY_POLICIES["tool_call"]
        return await workflow.execute_activity(
            FoundationActivity.execute,
            args=[request, context],
            start_to_close_timeout=timedelta(
                seconds=policy.start_to_close_timeout_seconds
            ),
            schedule_to_close_timeout=timedelta(
                seconds=policy.schedule_to_close_timeout_seconds
            ),
            retry_policy=RetryPolicy(maximum_attempts=policy.maximum_attempts),
        )
