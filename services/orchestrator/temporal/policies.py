from __future__ import annotations

from dataclasses import dataclass

PERMANENT_ACTIVITY_ERROR_TYPES: tuple[str, ...] = (
    "continuum.validation",
    "continuum.authorization",
    "continuum.policy_denied",
    "continuum.permanent",
)
FOUNDATION_TASK_QUEUE = "continuum.foundation"


@dataclass(frozen=True, slots=True)
class ActivityPolicy:
    maximum_attempts: int
    start_to_close_timeout_seconds: int
    schedule_to_close_timeout_seconds: int
    heartbeat_timeout_seconds: int | None = None
    cancellable: bool = True
    non_retryable_error_types: tuple[str, ...] = PERMANENT_ACTIVITY_ERROR_TYPES


# Temporal terminates a Workflow Execution once its Event History exceeds this
# many events; a warning is emitted from 10,240 onward. A Continue-As-New
# threshold at or above the termination limit can never be reached, so the
# Workflow is killed instead of continuing. Continuum's own threshold MUST stay
# well below this value.
TEMPORAL_HISTORY_TERMINATION_EVENTS: int = 51_200


@dataclass(frozen=True, slots=True)
class ContinueAsNewPolicy:
    max_events: int
    max_age_seconds: int

    def __post_init__(self) -> None:
        if self.max_events <= 0:
            raise ValueError("max_events must be positive")
        if self.max_age_seconds <= 0:
            raise ValueError("max_age_seconds must be positive")
        if self.max_events >= TEMPORAL_HISTORY_TERMINATION_EVENTS:
            raise ValueError(
                f"max_events={self.max_events} is at or above Temporal's history "
                f"termination limit ({TEMPORAL_HISTORY_TERMINATION_EVENTS}); the "
                "Continue-As-New branch could never be reached"
            )


@dataclass(frozen=True, slots=True)
class WorkerVersioningPolicy:
    rollback_supported: bool
    preview_only_required: bool
    deployment_strategy: str


TASK_QUEUES: tuple[str, ...] = (
    FOUNDATION_TASK_QUEUE,
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

# v1.2 Temporal execution contract: Continue-As-New at >8,000 history events or
# recurring execution >24h. 8,000 is an intentionally conservative Continuum
# threshold rather than a Temporal platform maximum -- it preserves headroom
# below TEMPORAL_HISTORY_TERMINATION_EVENTS.
CONTINUE_AS_NEW = ContinueAsNewPolicy(
    max_events=8_000,
    max_age_seconds=24 * 3600,
)

WORKER_VERSIONING = WorkerVersioningPolicy(
    rollback_supported=True,
    preview_only_required=False,
    deployment_strategy="stable-versioned-workers",
)
