from __future__ import annotations

from datetime import timedelta
from typing import NotRequired, TypedDict

from temporalio import activity, workflow
from temporalio.common import RetryPolicy, VersioningBehavior
from temporalio.exceptions import ApplicationError

from services.orchestrator.temporal.activities import (
    build_activity_context,
    execute_foundation_activity,
)
from services.orchestrator.temporal.contracts import (
    ActivityContext,
    WorkflowRequest,
    WorkflowResult,
)
from services.orchestrator.temporal.policies import (
    ACTIVITY_POLICIES,
    FOUNDATION_TASK_QUEUE,
)
from services.orchestrator.temporal.workflows import (
    FOUNDATION_ACTIVITY_CONTEXT_V1_PATCH,
    validate_workflow_request,
)

# FOUNDATION_TASK_QUEUE is re-exported deliberately: the Temporal test modules
# import it from here alongside FoundationActivity and FoundationWorkflow, so a
# worker and the queue it serves are named from one place. Without __all__ it
# reads as an unused import and a lint autofix deletes it, breaking all three
# test modules at import time.
__all__ = [
    "ActivityExecutionOptions",
    "FOUNDATION_TASK_QUEUE",
    "FoundationActivity",
    "FoundationWorkflow",
    "activity_execution_options",
]

class ActivityExecutionOptions(TypedDict):
    """Keyword arguments for workflow.execute_activity.

    Typed rather than dict[str, object] so the ** unpacking below can be
    checked: against a plain object-valued dict no execute_activity overload
    matches, and its return type degrades to Any.
    """

    start_to_close_timeout: timedelta
    schedule_to_close_timeout: timedelta
    retry_policy: RetryPolicy
    cancellation_type: workflow.ActivityCancellationType
    heartbeat_timeout: NotRequired[timedelta]


def activity_execution_options(policy_name: str) -> ActivityExecutionOptions:
    policy = ACTIVITY_POLICIES[policy_name]
    options: ActivityExecutionOptions = {
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
        try:
            validate_workflow_request(request)
        except ValueError as exc:
            raise ApplicationError(
                str(exc),
                type="continuum.validation",
                non_retryable=True,
            ) from None
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
