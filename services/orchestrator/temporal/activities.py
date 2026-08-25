from __future__ import annotations

from services.orchestrator.temporal.contracts import ActivityContext, WorkflowRequest, WorkflowResult


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
