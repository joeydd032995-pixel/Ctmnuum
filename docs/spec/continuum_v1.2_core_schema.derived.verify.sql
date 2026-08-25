-- Verification assertions for the DERIVED core schema.
--
-- Applied after continuum_v1.2_core_schema.derived.sql against PostgreSQL 18 +
-- pgvector. Proves the reconstruction is executable and that the invariants the
-- v1.2 report states as hard gates are actually enforced by the schema rather
-- than merely described in prose.

\set ON_ERROR_STOP on

-- 1. PostgreSQL 18 baseline                                            [V12]
DO $$
BEGIN
    IF current_setting('server_version_num')::integer < 180000 THEN
        RAISE EXCEPTION 'PostgreSQL 18+ required, got %', current_setting('server_version');
    END IF;
END
$$;

-- 2. All 25 tables named by v1.2 exist                                 [V12]
DO $$
DECLARE
    expected text[] := ARRAY[
        'users','workspaces','workspace_members','runs','artifacts','agents',
        'agent_versions','models','model_metrics','evidence','claims',
        'claim_evidence','memories','memory_embeddings','memory_edges',
        'failures','tools','tool_versions','tool_executions','evaluations',
        'evaluation_results','mutations','mutation_evaluations','events',
        'cost_events'
    ];
    missing text[];
BEGIN
    SELECT array_agg(e) INTO missing
    FROM unnest(expected) AS e
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'continuum' AND table_name = e
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing v1.2 tables: %', missing;
    END IF;
    RAISE NOTICE 'all 25 v1.2 tables present';
END
$$;

-- 3. memory_embeddings matches the one complete source DDL block       [V12]
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname='continuum' AND c.relname='memory_embeddings'
          AND a.attname='embedding'
          AND format_type(a.atttypid, a.atttypmod) = 'vector(512)'
    ) THEN
        RAISE EXCEPTION 'memory_embeddings.embedding is not vector(512)';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname='continuum'
          AND indexname='memory_embeddings_hnsw_cosine_idx'
          AND indexdef LIKE '%hnsw%vector_cosine_ops%'
    ) THEN
        RAISE EXCEPTION 'HNSW cosine index missing on memory_embeddings';
    END IF;
    RAISE NOTICE 'memory_embeddings vector(512) + HNSW cosine index verified';
END
$$;

-- 4. Tenant context fails closed when app.workspace_id is unset        [V12]
DO $$
BEGIN
    IF continuum.current_workspace_id() IS NOT NULL THEN
        RAISE EXCEPTION 'workspace context must fail closed when unset';
    END IF;
    RAISE NOTICE 'tenant context fails closed';
END
$$;

-- 5. RLS is enabled AND forced on every tenant-scoped table            [V12]
DO $$
DECLARE
    bad text[];
BEGIN
    SELECT array_agg(c.relname::text) INTO bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname='continuum'
      AND c.relkind='r'
      AND c.relname NOT IN ('users','models')   -- [DECISION] not workspace-scoped
      AND (c.relrowsecurity IS FALSE OR c.relforcerowsecurity IS FALSE);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'RLS not enabled/forced on: %', bad;
    END IF;
    RAISE NOTICE 'RLS enabled and forced on all tenant-scoped tables';
END
$$;

-- 6. Event store rejects UPDATE and DELETE                             [V12]
INSERT INTO continuum.workspaces (id, name)
VALUES ('00000000-0000-0000-0000-0000000000aa', 'verify-ws');

INSERT INTO continuum.events (
    event_id, workspace_id, event_type, schema_version,
    aggregate_type, aggregate_id, actor_type,
    payload, event_hash, occurred_at
) VALUES (
    '00000000-0000-0000-0000-0000000000e1',
    '00000000-0000-0000-0000-0000000000aa',
    'VerifyEvent', 1, 'workspace',
    '00000000-0000-0000-0000-0000000000aa', 'system',
    '{}'::jsonb, repeat('0', 64), now()
);

DO $$
BEGIN
    BEGIN
        UPDATE continuum.events SET event_type = 'Tampered'
        WHERE event_id = '00000000-0000-0000-0000-0000000000e1';
        RAISE EXCEPTION 'event store accepted an UPDATE';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'event store accepted an UPDATE' THEN RAISE; END IF;
    END;

    BEGIN
        DELETE FROM continuum.events
        WHERE event_id = '00000000-0000-0000-0000-0000000000e1';
        RAISE EXCEPTION 'event store accepted a DELETE';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'event store accepted a DELETE' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'event store is append-only';
END
$$;

-- 7. Risk-3/4 tools cannot exist without approval_required             [V12]
INSERT INTO continuum.tools (id, name, purpose)
VALUES ('00000000-0000-0000-0000-0000000000b1', 'verify-tool', 'verification tool')
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    BEGIN
        INSERT INTO continuum.tool_versions (
            id, tool_id, version, risk_level, side_effect,
            idempotency_required, idempotency_strategy,
            permissions, resources, approval_required,
            input_schema, output_schema, manifest_hash
        ) VALUES (
            '00000000-0000-0000-0000-0000000000c1',
            '00000000-0000-0000-0000-0000000000b1',
            '1.0.0', 4, 'irreversible_external_write',
            true, 'caller_key',
            '{}'::jsonb, '{}'::jsonb, false,       -- risk 4 without approval
            '{}'::jsonb, '{}'::jsonb, repeat('0', 64)
        );
        RAISE EXCEPTION 'risk-4 tool accepted without approval_required';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'risk-3/4 tools require approval: enforced';
    END;
END
$$;

-- 8. A mutation cannot reach 'promoted' without a human approver       [V12]
DO $$
BEGIN
    BEGIN
        INSERT INTO continuum.mutations (
            id, class, target_type, target_id, hypothesis, stage
        ) VALUES (
            '00000000-0000-0000-0000-0000000000d1',
            'prompt', 'agent_version',
            '00000000-0000-0000-0000-0000000000aa',
            'autonomous promotion attempt', 'promoted'
        );
        RAISE EXCEPTION 'mutation promoted without human approval';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'autonomous production promotion: blocked';
    END;
END
$$;

-- 9. Operational roles carry NOLOGIN NOBYPASSRLS even if pre-provisioned  [V12]
DO $$
DECLARE bad text[];
BEGIN
    SELECT array_agg(rolname::text) INTO bad
    FROM pg_roles
    WHERE rolname LIKE 'continuum\\_%' AND (rolbypassrls OR rolcanlogin);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'roles with BYPASSRLS or LOGIN: %', bad;
    END IF;
    RAISE NOTICE 'operational roles are NOLOGIN NOBYPASSRLS';
END
$$;

-- 10. A child row cannot reference a parent owned by another workspace   [V12]
INSERT INTO continuum.workspaces (id, name)
VALUES ('00000000-0000-0000-0000-0000000000bb', 'other-tenant');

INSERT INTO continuum.memories (id, workspace_id, memory_type, content, content_hash)
VALUES ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000bb',
        'semantic', 'tenant B memory', repeat('0', 64));

DO $$
BEGIN
    BEGIN
        -- workspace A embedding pointing at workspace B's memory
        INSERT INTO continuum.memory_embeddings (
            memory_id, workspace_id, embedding_model, source_content_hash, embedding
        ) VALUES (
            '00000000-0000-0000-0000-0000000000a1',
            '00000000-0000-0000-0000-0000000000aa',
            'text-embedding-3-small', repeat('0', 64),
            ('[' || array_to_string(array_fill(0, ARRAY[512]), ',') || ']')::vector
        );
        RAISE EXCEPTION 'cross-workspace association was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'cross-workspace parent reference: rejected';
    END;
END
$$;

-- 11. A promoted tool version cannot exist without an immutable digest   [V12]
DO $$
BEGIN
    BEGIN
        INSERT INTO continuum.tool_versions (
            id, tool_id, version, risk_level, side_effect,
            idempotency_required, idempotency_strategy,
            permissions, resources, approval_required,
            input_schema, output_schema, manifest_hash, promotion_stage
        ) VALUES (
            '00000000-0000-0000-0000-0000000000c2',
            '00000000-0000-0000-0000-0000000000b1',
            '1.0.1', 1, 'none', true, 'caller_key',
            '{}'::jsonb, '{}'::jsonb, false,
            '{}'::jsonb, '{}'::jsonb, repeat('0', 64), 'promoted'
        );
        RAISE EXCEPTION 'promoted tool version accepted without a digest';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'promoted tool version requires a digest: enforced';
    END;
END
$$;

-- 12. A risk-3/4 execution cannot be recorded without an approval        [V12]
INSERT INTO continuum.tool_versions (
    id, tool_id, version, risk_level, side_effect,
    idempotency_required, idempotency_strategy,
    permissions, resources, approval_required,
    input_schema, output_schema, manifest_hash
) VALUES (
    '00000000-0000-0000-0000-0000000000c3',
    '00000000-0000-0000-0000-0000000000b1',
    '2.0.0', 4, 'irreversible_external_write', true, 'caller_key',
    '{}'::jsonb, '{}'::jsonb, true,
    '{}'::jsonb, '{}'::jsonb, repeat('0', 64)
);

DO $$
BEGIN
    BEGIN
        INSERT INTO continuum.tool_executions (
            id, workspace_id, tool_version_id, idempotency_key, status
        ) VALUES (
            '00000000-0000-0000-0000-0000000000f1',
            '00000000-0000-0000-0000-0000000000aa',
            '00000000-0000-0000-0000-0000000000c3',
            'verify-key-1', 'pending'
        );
        RAISE EXCEPTION 'risk-4 execution accepted without approval';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'risk-3/4 execution requires recorded approval: enforced';
    END;
END
$$;

-- 13. Built-in agents (workspace_id IS NULL) remain readable            [DERIVED]
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname='continuum' AND tablename='agents'
          AND policyname='agents_read' AND qual LIKE '%IS NULL%'
    ) THEN
        RAISE EXCEPTION 'built-in agents would be invisible to every tenant';
    END IF;
    RAISE NOTICE 'built-in agents remain readable under the tenant policy';
END
$$;

SELECT 'DERIVED CORE SCHEMA VERIFICATION PASSED' AS result;
