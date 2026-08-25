from __future__ import annotations

from services.orchestrator.temporal.contracts import WorkflowRequest
from services.orchestrator.temporal.policies import CONTINUE_AS_NEW


def should_continue_as_new(*, event_count: int, age_seconds: int) -> bool:
    return (
        event_count >= CONTINUE_AS_NEW.max_events
        or age_seconds >= CONTINUE_AS_NEW.max_age_seconds
    )


def validate_workflow_request(request: WorkflowRequest) -> None:
    if not request.workspace_id.strip():
        raise ValueError("workspace_id is required")
    if not request.run_id.strip():
        raise ValueError("run_id is required")
    if not request.task_id.strip():
        raise ValueError("task_id is required")
    if not request.objective.strip():
        raise ValueError("objective is required")
