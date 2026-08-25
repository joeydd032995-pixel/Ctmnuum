from __future__ import annotations

from dataclasses import dataclass

PERMANENT_ACTIVITY_ERROR_TYPES: tuple[str, ...] = (
    "continuum.validation",
    "continuum.authorization",
    "continuum.policy_denied",
    "continuum.permanent",
)


@dataclass(frozen=True, slots=True)
class ActivityPolicy:
    maximum_attempts: int
    start_to_close_timeout_seconds: int
    schedule_to_close_timeout_seconds: int
    heartbeat_timeout_seconds: int | None = None
    cancellable: bool = True
    non_retryable_error_types: tuple[str, ...] = PERMANENT_ACTIVITY_ERROR_TYPES


@dataclass(frozen=True, slots=True)
class ContinueAsNewPolicy:
    max_events: int
    max_age_seconds: int


@dataclass(frozen=True, slots=True)
class WorkerVersioningPolicy:
    rollback_supported: bool
    preview_only_required: bool
    deployment_strategy: str


TASK_QUEUES: tuple[str, ...] = (
    "continuum.interactive",
    "continuum.standard",
    "continuum.background",
    "continuum.evaluation",
    "continuum.mutation",
    "continuum.sandbox",
)

PRIORITIES: dict[str, int] = {
    "interactive": 80,
    "production_action": 70,
    "standard": 50,
    "background": 30,
    "memory_distillation": 20,
    "evaluation": 15,
    "mutation": 10,
}

ACTIVITY_POLICIES: dict[str, ActivityPolicy] = {
    "model_call": ActivityPolicy(
        maximum_attempts=3,
        start_to_close_timeout_seconds=120,
        schedule_to_close_timeout_seconds=300,
    ),
    "retrieval": ActivityPolicy(
        maximum_attempts=3,
        start_to_close_timeout_seconds=60,
        schedule_to_close_timeout_seconds=180,
    ),
    "tool_call": ActivityPolicy(
        maximum_attempts=2,
        start_to_close_timeout_seconds=120,
        schedule_to_close_timeout_seconds=300,
    ),
    "long_running": ActivityPolicy(
        maximum_attempts=2,
        start_to_close_timeout_seconds=3600,
        schedule_to_close_timeout_seconds=7200,
        heartbeat_timeout_seconds=30,
    ),
}

CONTINUE_AS_NEW = ContinueAsNewPolicy(
    max_events=100_000,
    max_age_seconds=7 * 24 * 3600,
)

WORKER_VERSIONING = WorkerVersioningPolicy(
    rollback_supported=True,
    preview_only_required=False,
    deployment_strategy="stable-versioned-workers",
)
