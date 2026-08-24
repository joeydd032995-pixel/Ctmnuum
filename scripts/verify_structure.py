from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FILES = (
    ".editorconfig",
    ".gitignore",
    ".node-version",
    ".python-version",
    "README.md",
    "package.json",
    "pnpm-lock.yaml",
    "pnpm-workspace.yaml",
    "pyproject.toml",
    "turbo.json",
    "uv.lock",
)

REQUIRED_DIRS = (
    "apps/web",
    "apps/cli",
    "services/gateway",
    "services/orchestrator",
    "services/agent_runtime",
    "services/context_compiler",
    "services/memory",
    "services/evaluator",
    "services/watcher",
    "services/model_router",
    "services/economic_router",
    "services/resource_scheduler",
    "services/action_broker",
    "services/sandbox_broker",
    "services/tool_factory",
    "services/ingestion",
    "packages/continuum_core",
    "packages/continuum_db",
    "packages/continuum_models",
    "packages/continuum_security",
    "packages/continuum_telemetry",
    "packages/continuum_economics",
    "packages/continuum_testing",
    "agents",
    "prompts",
    "policies",
    "schemas",
    "evals",
    "tools",
    "infra/docker",
    "infra/terraform",
    "infra/kubernetes",
    "infra/helm",
    "infra/temporal",
    "infra/otel",
    "infra/monitoring",
    "tests/unit",
    "tests/integration",
    "tests/e2e",
    "tests/chaos",
    "tests/security",
    "tests/performance",
    "docs",
)


def main() -> int:
    missing_files = [path for path in REQUIRED_FILES if not (ROOT / path).is_file()]
    missing_dirs = [path for path in REQUIRED_DIRS if not (ROOT / path).is_dir()]

    if missing_files or missing_dirs:
        if missing_files:
            print("Missing required files:")
            for path in missing_files:
                print(f"  - {path}")
        if missing_dirs:
            print("Missing required directories:")
            for path in missing_dirs:
                print(f"  - {path}")
        return 1

    print("Continuum Foundation repository structure is complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
