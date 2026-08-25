from __future__ import annotations

from datetime import timedelta

from temporalio import activity, workflow
from temporalio.common import RetryPolicy, VersioningBehavior

from services.orchestrator.temporal.activities import (
    build_activity_context,
    execute_foundation_activity,
)
from services.orchestrator.temporal.contracts import ActivityContext, WorkflowRequest, WorkflowResult
from services.orchestrator.temporal.policies import ACTIVITY_POLICIES
from services.orchestrator.temporal.workflows import (
    FOUNDATION_ACTIVITY_CONTEXT_V1_PATCH,
    validate_workflow_request,
)

FOUNDATION_TASK_QUEUE = "continuum.foundation"


def activity_execution_options(policy_name: str) -> dict[str, object]:
    policy = ACTIVITY_POLICIES[policy_name]
    options: dict[str, object] = {
        "start_to_close_timeout": timedelta(
            seconds=policy.start_to_close_timeout_seconds
        ),
        "schedule_to_close_timeout": timedelta(
            seconds=policy.schedule_to_close_timeout_seconds
        ),
        "retry_policy": RetryPolicy(
            maximum_attempts=policy.maximum_attempts,
            non_retryable_error_types=policy.non_retryable_error_types,
        ),
        "cancellation_type": (
            workflow.ActivityCancellationType.TRY_CANCEL
            if policy.cancellable
            else workflow.ActivityCancellationType.ABANDON
        ),
    }
    if policy.heartbeat_timeout_seconds is not None:
        options["heartbeat_timeout"] = timedelta(
            seconds=policy.heartbeat_timeout_seconds
        )
    return options


@activity.defn(name="continuum.foundation.execute")
async def _foundation_execute(
    request: WorkflowRequest,
    context: ActivityContext,
) -> WorkflowResult:
    return execute_foundation_activity(request=request, context=context)


class FoundationActivity:
    execute = staticmethod(_foundation_execute)


@workflow.defn(
    name="continuum.foundation.workflow",
    versioning_behavior=VersioningBehavior.PINNED,
)
class FoundationWorkflow:
    @workflow.run
    async def run(self, request: WorkflowRequest) -> WorkflowResult:
        validate_workflow_request(request)
        activity_context_version = (
            "v1" if workflow.patched(FOUNDATION_ACTIVITY_CONTEXT_V1_PATCH) else None
        )
        context = build_activity_context(
            request,
            activity_context_version=activity_context_version,
        )
        return await workflow.execute_activity(
            FoundationActivity.execute,
            args=[request, context],
            **activity_execution_options("tool_call"),
        )
