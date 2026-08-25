from __future__ import annotations

from dataclasses import dataclass

from temporalio.common import VersioningBehavior, WorkerDeploymentVersion
from temporalio.worker import WorkerDeploymentConfig

from services.orchestrator.temporal.policies import TASK_QUEUES, WORKER_VERSIONING

FOUNDATION_DEPLOYMENT_NAME = "continuum-orchestrator"


@dataclass(frozen=True, slots=True)
class WorkerDeployment:
    deployment_name: str
    build_id: str
    task_queues: tuple[str, ...]
    rollback_build_id: str | None
    preview_features_enabled: bool


def build_worker_deployment(*, build_id: str, rollback_build_id: str | None = None) -> WorkerDeployment:
    if not build_id.strip():
        raise ValueError("build_id is required")
    if rollback_build_id is not None and not rollback_build_id.strip():
        raise ValueError("rollback_build_id must be non-empty when provided")
    if rollback_build_id == build_id:
        raise ValueError("rollback_build_id must differ from build_id")
    return WorkerDeployment(
        deployment_name=FOUNDATION_DEPLOYMENT_NAME,
        build_id=build_id,
        task_queues=TASK_QUEUES,
        rollback_build_id=rollback_build_id,
        preview_features_enabled=WORKER_VERSIONING.preview_only_required,
    )


def rollback_supported(deployment: WorkerDeployment) -> bool:
    return WORKER_VERSIONING.rollback_supported and bool(deployment.rollback_build_id)


def select_rollback_build(deployment: WorkerDeployment) -> str:
    if not rollback_supported(deployment) or deployment.rollback_build_id is None:
        raise ValueError("rollback build is not configured")
    return deployment.rollback_build_id


def build_temporal_deployment_config(
    deployment: WorkerDeployment,
) -> WorkerDeploymentConfig:
    return WorkerDeploymentConfig(
        version=WorkerDeploymentVersion(
            deployment_name=deployment.deployment_name,
            build_id=deployment.build_id,
        ),
        use_worker_versioning=True,
        default_versioning_behavior=VersioningBehavior.UNSPECIFIED,
    )
