from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ActivityContext:
    workspace_id: str
    run_id: str
    task_id: str
    activity_id: str
    attempt: int
    idempotency_key: str
    traceparent: str | None = None


@dataclass(frozen=True, slots=True)
class WorkflowRequest:
    workspace_id: str
    run_id: str
    task_id: str
    objective: str
    event_count: int = 0
    age_seconds: int = 0


@dataclass(frozen=True, slots=True)
class WorkflowResult:
    run_id: str
    task_id: str
    artifact_ref: str
    status: str
