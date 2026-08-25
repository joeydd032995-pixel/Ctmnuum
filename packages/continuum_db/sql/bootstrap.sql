-- Continuum v1.2 database bootstrap.
--
-- Scope is intentionally limited to source-backed platform invariants. The
-- field-level domain DDL remains blocked on recovery/reconstruction of the
-- machine-readable v1.2 core implementation artifact (GitHub issue #2).
--
-- PostgreSQL baseline: 18

CREATE SCHEMA IF NOT EXISTS continuum;

CREATE EXTENSION IF NOT EXISTS vector;

-- Operational group roles. Login/user credentials are provisioned separately
-- by environment-specific infrastructure. These names are implementation
-- decisions documented in ADR-0001; v1.2 requires the roles to be distinct.
CREATE ROLE continuum_app NOLOGIN NOBYPASSRLS;
CREATE ROLE continuum_migration NOLOGIN NOBYPASSRLS;
CREATE ROLE continuum_maintenance NOLOGIN NOBYPASSRLS;

-- RLS policies on tenant-scoped tables will compare workspace_id against this
-- transaction-local setting. When the setting is absent/empty, NULL is
-- returned; a normal equality policy therefore fails closed.
CREATE OR REPLACE FUNCTION continuum.current_workspace_id()
RETURNS uuid
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT NULLIF(current_setting('app.workspace_id', true), '')::uuid;
$$;

REVOKE ALL ON SCHEMA continuum FROM PUBLIC;
GRANT USAGE ON SCHEMA continuum TO continuum_app;
GRANT USAGE, CREATE ON SCHEMA continuum TO continuum_migration;
GRANT USAGE ON SCHEMA continuum TO continuum_maintenance;

COMMENT ON FUNCTION continuum.current_workspace_id() IS
    'Returns the transaction-scoped app.workspace_id used by Continuum RLS policies.';
