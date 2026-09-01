from __future__ import annotations

from services.orchestrator.temporal.contracts import (
    ActivityContext,
    WorkflowRequest,
    WorkflowResult,
)


def build_activity_context(
    request: WorkflowRequest,
    *,
    activity_context_version: str | None,
) -> ActivityContext:
    activity_name = "foundation.execute"
    if activity_context_version is not None:
        activity_name = f"{activity_name}.{activity_context_version}"
    return ActivityContext(
        workspace_id=request.workspace_id,
        run_id=request.run_id,
        task_id=request.task_id,
        activity_id=activity_name,
        attempt=1,
        idempotency_key=(
            f"{request.workspace_id}:{request.run_id}:{request.task_id}:{activity_name}"
        ),
    )


def execute_foundation_activity(
    *,
    request: WorkflowRequest,
    context: ActivityContext,
) -> WorkflowResult:
    if context.run_id != request.run_id or context.task_id != request.task_id:
        raise ValueError("activity context does not match workflow request")
    return WorkflowResult(
        run_id=request.run_id,
        task_id=request.task_id,
        artifact_ref=f"artifact://foundation/{context.idempotency_key}",
        status="completed",
    )
