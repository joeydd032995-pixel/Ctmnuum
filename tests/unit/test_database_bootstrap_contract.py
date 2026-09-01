from __future__ import annotations

import re
import unittest
from pathlib import Path
from typing import ClassVar

ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = ROOT / "packages" / "continuum_db" / "sql" / "bootstrap.sql"


class DatabaseBootstrapContractTests(unittest.TestCase):
    # Declared because setUpClass populates them: without the annotations every
    # use below reads as an attribute that is never assigned.
    sql: ClassVar[str]
    normalized: ClassVar[str]

    @classmethod
    def setUpClass(cls) -> None:
        if not BOOTSTRAP.is_file():
            raise AssertionError(f"Missing v1.2 database bootstrap: {BOOTSTRAP.relative_to(ROOT)}")
        cls.sql = BOOTSTRAP.read_text(encoding="utf-8")
        cls.normalized = re.sub(r"\s+", " ", cls.sql.lower())

    def test_continuum_schema_exists(self) -> None:
        self.assertIn("create schema if not exists continuum", self.normalized)

    def test_pgvector_extension_is_enabled(self) -> None:
        self.assertRegex(self.normalized, r"create extension if not exists vector")

    def test_three_operational_roles_are_distinct(self) -> None:
        for role in ("continuum_app", "continuum_migration", "continuum_maintenance"):
            self.assertRegex(self.normalized, rf"create role {role}\b")

    def test_application_role_cannot_bypass_rls(self) -> None:
        app_role = re.search(
            r"create role continuum_app(?P<body>.*?);",
            self.normalized,
        )
        self.assertIsNotNone(app_role, "continuum_app role definition missing")
        assert app_role is not None
        self.assertIn("nobypassrls", app_role.group("body"))
        self.assertNotIn("bypassrls", app_role.group("body").replace("nobypassrls", ""))

    def test_workspace_context_is_transaction_setting_based(self) -> None:
        self.assertIn("current_setting('app.workspace_id', true)", self.normalized)
        self.assertIn("::uuid", self.normalized)

    def test_bootstrap_does_not_create_domain_tables_from_missing_artifact(self) -> None:
        # The standalone v1.2 core DDL artifact is currently unavailable.  Until it is
        # recovered, bootstrap may establish platform invariants but must not invent
        # field-level domain tables and present them as source-derived v1.2 DDL.
        self.assertNotRegex(self.normalized, r"create table continuum\.")


if __name__ == "__main__":
    unittest.main()
