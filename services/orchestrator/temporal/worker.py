from __future__ import annotations

from dataclasses import dataclass

from services.orchestrator.temporal.policies import TASK_QUEUES, WORKER_VERSIONING


@dataclass(frozen=True, slots=True)
class WorkerDeployment:
    build_id: str
    task_queues: tuple[str, ...]
    rollback_build_id: str | None
    preview_features_enabled: bool


def build_worker_deployment(*, build_id: str, rollback_build_id: str | None = None) -> WorkerDeployment:
    if not build_id.strip():
        raise ValueError("build_id is required")
    return WorkerDeployment(
        build_id=build_id,
        task_queues=TASK_QUEUES,
        rollback_build_id=rollback_build_id,
        preview_features_enabled=WORKER_VERSIONING.preview_only_required,
    )


def rollback_supported(deployment: WorkerDeployment) -> bool:
    return WORKER_VERSIONING.rollback_supported and bool(deployment.rollback_build_id)
