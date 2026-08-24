\set ON_ERROR_STOP on

DO $$
BEGIN
    IF current_setting('server_version_num')::integer < 180000 THEN
        RAISE EXCEPTION 'PostgreSQL 18+ required, got %', current_setting('server_version');
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'vector'
    ) THEN
        RAISE EXCEPTION 'pgvector extension is not installed';
    END IF;
END
$$;

DO $$
DECLARE
    role_name text;
    bypass boolean;
BEGIN
    FOREACH role_name IN ARRAY ARRAY[
        'continuum_app',
        'continuum_migration',
        'continuum_maintenance'
    ]
    LOOP
        SELECT rolbypassrls
        INTO bypass
        FROM pg_roles
        WHERE rolname = role_name;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'required role % is missing', role_name;
        END IF;

        IF bypass THEN
            RAISE EXCEPTION 'role % unexpectedly has BYPASSRLS', role_name;
        END IF;
    END LOOP;
END
$$;

DO $$
BEGIN
    IF continuum.current_workspace_id() IS NOT NULL THEN
        RAISE EXCEPTION 'workspace context must fail closed when unset';
    END IF;
END
$$;

BEGIN;
SET LOCAL app.workspace_id = '00000000-0000-0000-0000-000000000123';

DO $$
BEGIN
    IF continuum.current_workspace_id()
       <> '00000000-0000-0000-0000-000000000123'::uuid THEN
        RAISE EXCEPTION 'transaction-scoped workspace context was not returned';
    END IF;
END
$$;

COMMIT;

DO $$
BEGIN
    IF continuum.current_workspace_id() IS NOT NULL THEN
        RAISE EXCEPTION 'SET LOCAL leaked beyond the transaction';
    END IF;
END
$$;
