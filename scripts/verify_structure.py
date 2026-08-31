from __future__ import annotations

import json
import re
import tomllib
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


def _runtime_pin_errors() -> list[str]:
    """Check that the pinned runtimes agree with each other.

    [FND-REPO-G1] requires pinned language runtimes to be *verified*, not merely
    present. Existence checks pass while `.python-version` says 3.13 and
    `pyproject.toml` requires 3.14 -- a disagreement nothing else would catch
    until a build resolved the wrong interpreter.
    """

    errors: list[str] = []
    pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    package_json = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))
    continuum = pyproject.get("tool", {}).get("continuum", {})

    # Python: .python-version is exact, [tool.continuum].python is major.minor.
    python_version = (ROOT / ".python-version").read_text(encoding="utf-8").strip()
    declared_python = continuum.get("python")
    if not declared_python:
        errors.append("pyproject.toml [tool.continuum] does not declare python")
    elif not python_version.startswith(f"{declared_python}."):
        errors.append(
            f".python-version '{python_version}' does not match "
            f"[tool.continuum].python '{declared_python}'"
        )

    # Node: .node-version must equal the lower bound engines.node allows.
    node_version = (ROOT / ".node-version").read_text(encoding="utf-8").strip()
    engines_node = package_json.get("engines", {}).get("node", "")
    lower_bound = re.match(r">=\s*([0-9]+\.[0-9]+\.[0-9]+)", engines_node)
    if not lower_bound:
        errors.append(f"package.json engines.node '{engines_node}' has no >= lower bound")
    elif node_version != lower_bound.group(1):
        errors.append(
            f".node-version '{node_version}' does not match the engines.node "
            f"lower bound '{lower_bound.group(1)}'"
        )

    # The package manager itself must be pinned exactly, or CI can resolve a
    # different pnpm than a contributor does.
    package_manager = package_json.get("packageManager", "")
    if not re.fullmatch(r"pnpm@[0-9]+\.[0-9]+\.[0-9]+", package_manager):
        errors.append(f"package.json packageManager '{package_manager}' is not an exact pnpm pin")

    # temporalio's version is part of the contract, not a floor (CLAUDE.md), so
    # the dependency and the recorded pin must not drift apart.
    declared_temporalio = continuum.get("temporalio")
    dependencies = pyproject.get("project", {}).get("dependencies", [])
    pinned = [d for d in dependencies if d.startswith("temporalio==")]
    if not pinned:
        errors.append("pyproject.toml [project].dependencies has no exact temporalio pin")
    elif declared_temporalio and pinned[0] != f"temporalio=={declared_temporalio}":
        errors.append(
            f"dependency '{pinned[0]}' does not match "
            f"[tool.continuum].temporalio '{declared_temporalio}'"
        )

    return errors


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

    pin_errors = _runtime_pin_errors()
    if pin_errors:
        print("Runtime pins disagree:")
        for message in pin_errors:
            print(f"  - {message}")
        return 1

    print("Continuum Foundation repository structure and runtime pins are consistent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
