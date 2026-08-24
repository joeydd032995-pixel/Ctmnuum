# Ctmnuum

Continuum is a persistent autonomous reasoning environment that accumulates verified knowledge, evidence, memory, failures, evaluations, tools, and controlled system improvements.

This repository is being implemented from the Continuum v1.2 Implementation Specification and its phase-gated execution plan.

## Current phase

**Phase 1 — Foundation**

Initial targets:

- Python/FastAPI service foundation
- Next.js/TypeScript control-plane shell
- PostgreSQL + pgvector schema/migrations with tenant-isolation foundations
- Temporal workflow/activity foundation
- S3 artifact abstraction
- OpenTelemetry instrumentation
- Docker Compose local environment
- Kubernetes/EKS-ready manifests and infrastructure layout
- CI, tests, and hard acceptance-gate scaffolding

Advanced autonomous components (Watcher, Tool Factory, Mutation Engine, production self-improvement) remain disabled until their prerequisite acceptance gates are proven.
