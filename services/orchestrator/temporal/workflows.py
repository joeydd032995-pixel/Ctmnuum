from __future__ import annotations

from services.orchestrator.temporal.contracts import WorkflowRequest
from services.orchestrator.temporal.policies import CONTINUE_AS_NEW

FOUNDATION_ACTIVITY_CONTEXT_V1_PATCH = "foundation-activity-context-v1"


def should_continue_as_new(*, event_count: int, age_seconds: int) -> bool:
    # The v1.2 contract is strict: Continue-As-New above 8,000 history events or
    # above 24h of recurring execution. Comparing with >= would fire one event
    # and one second early, at the threshold rather than beyond it.
    return (
        event_count > CONTINUE_AS_NEW.max_events
        or age_seconds > CONTINUE_AS_NEW.max_age_seconds
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
