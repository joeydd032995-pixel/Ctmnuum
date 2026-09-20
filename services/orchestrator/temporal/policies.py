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
class RetryPolicySpec:
    """One of the four retry policies v1.2 states by name.

    [V12] Every field below is reproduced from the v1.2 report. These values are
    recovered specification text, not a reconstruction: do not adjust them
    without a source that supersedes v1.2.
    """

    initial_interval_seconds: float
    backoff_coefficient: float
    maximum_interval_seconds: float
    maximum_attempts: int
    non_retryable_error_types: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.initial_interval_seconds <= 0:
            raise ValueError("initial_interval_seconds must be positive")
        if self.backoff_coefficient < 1:
            raise ValueError("backoff_coefficient below 1 shrinks the interval on retry")
        if self.maximum_interval_seconds < self.initial_interval_seconds:
            raise ValueError(
                f"maximum_interval_seconds={self.maximum_interval_seconds} is below "
                f"initial_interval_seconds={self.initial_interval_seconds}; the ceiling "
                "would cap the first retry"
            )
        if self.maximum_attempts <= 0:
            raise ValueError(
                "maximum_attempts must be positive; v1.2 requires paid model and API "
                "operations to carry an explicit cap, because Temporal's default retry "
                "behaviour is effectively unbounded"
            )


# [V12] Reproduced verbatim from the v1.2 Temporal definitions. Before this they
# were stated in the specification and encoded nowhere -- finding F-07.
RETRY_POLICIES: dict[str, RetryPolicySpec] = {
    "MODEL_RETRY": RetryPolicySpec(
        initial_interval_seconds=2,
        backoff_coefficient=2.0,
        maximum_interval_seconds=20,
        maximum_attempts=3,
        non_retryable_error_types=(
            "InvalidInputError",
            "ProviderBadRequestError",
            "PolicyDeniedError",
            "BudgetExceededError",
        ),
    ),
    "IO_RETRY": RetryPolicySpec(
        initial_interval_seconds=1,
        backoff_coefficient=2.0,
        maximum_interval_seconds=30,
        maximum_attempts=5,
    ),
    "SIDE_EFFECT_RETRY": RetryPolicySpec(
        initial_interval_seconds=2,
        backoff_coefficient=2.0,
        maximum_interval_seconds=30,
        maximum_attempts=3,
        non_retryable_error_types=(
            "PolicyDeniedError",
            "HumanApprovalRejected",
            "NonIdempotentActionError",
            "InvalidInputError",
        ),
    ),
    "SANDBOX_RETRY": RetryPolicySpec(
        initial_interval_seconds=5,
        backoff_coefficient=2.0,
        maximum_interval_seconds=30,
        maximum_attempts=2,
    ),
}


@dataclass(frozen=True, slots=True)
class ActivityPolicy:
    """Timeouts for an activity class, plus the v1.2 retry policy governing it.

    [DECISION: ADR-0007] The timeouts are the one item v1.2 explicitly delegates
    to the lost core artifact and never restates.

    [DERIVED] `retry_policy` is the mapping from an activity class to one of the
    four named v1.2 policies. v1.2 states the policies and states the classes,
    but never which governs which -- so the mapping is inferred, and named here
    rather than buried, because it decides real retry behaviour.
    """

    retry_policy: str
    start_to_close_timeout_seconds: int
    schedule_to_close_timeout_seconds: int
    heartbeat_timeout_seconds: int | None = None
    cancellable: bool = True

    def __post_init__(self) -> None:
        if self.retry_policy not in RETRY_POLICIES:
            raise ValueError(
                f"unknown retry policy '{self.retry_policy}'; v1.2 names {sorted(RETRY_POLICIES)}"
            )
        if self.schedule_to_close_timeout_seconds < self.start_to_close_timeout_seconds:
            raise ValueError(
                f"schedule_to_close_timeout_seconds="
                f"{self.schedule_to_close_timeout_seconds} is below "
                f"start_to_close_timeout_seconds={self.start_to_close_timeout_seconds}; "
                "a single attempt could not finish inside the overall deadline"
            )

    @property
    def retry(self) -> RetryPolicySpec:
        return RETRY_POLICIES[self.retry_policy]

    @property
    def maximum_attempts(self) -> int:
        """Read through to v1.2 rather than carrying a second copy.

        [DECISION: ADR-0007] These counts previously lived on the activity class
        and disagreed with the policy v1.2 states: `retrieval` capped at 3 where
        IO_RETRY says 5, `tool_call` at 2 where SIDE_EFFECT_RETRY says 3. Two
        sources for one number is how they drift apart, so there is now one.
        """
        return self.retry.maximum_attempts

    @property
    def non_retryable_error_types(self) -> tuple[str, ...]:
        """v1.2's per-policy list, plus Continuum's own permanent-error taxonomy.

        [DERIVED] The union, not a replacement. v1.2 names error types for
        MODEL_RETRY and SIDE_EFFECT_RETRY drawn from its own taxonomy; the
        `continuum.*` types are this implementation's and are permanent
        regardless of which policy applies. Dropping either set would make some
        terminal error retry.
        """
        return tuple(
            dict.fromkeys(self.retry.non_retryable_error_types + PERMANENT_ACTIVITY_ERROR_TYPES)
        )


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

# Timeouts: [DECISION: ADR-0007]. Retry policy per class: [DERIVED], reasoned in
# ADR-0007 -- a model call is MODEL_RETRY by name; retrieval is read-only I/O;
# a tool call is the side-effecting one v1.2 gates on approval and idempotency;
# long-running work is the sandboxed class, and the only one that heartbeats.
ACTIVITY_POLICIES: dict[str, ActivityPolicy] = {
    "model_call": ActivityPolicy(
        retry_policy="MODEL_RETRY",
        start_to_close_timeout_seconds=120,
        schedule_to_close_timeout_seconds=300,
    ),
    "retrieval": ActivityPolicy(
        retry_policy="IO_RETRY",
        start_to_close_timeout_seconds=60,
        schedule_to_close_timeout_seconds=180,
    ),
    "tool_call": ActivityPolicy(
        retry_policy="SIDE_EFFECT_RETRY",
        start_to_close_timeout_seconds=120,
        schedule_to_close_timeout_seconds=300,
    ),
    "long_running": ActivityPolicy(
        retry_policy="SANDBOX_RETRY",
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
