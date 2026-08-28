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

-- 11b. ...but a promoted version WITH a valid digest is accepted     [DERIVED]
INSERT INTO continuum.tool_versions (
    id, tool_id, version, risk_level, side_effect,
    idempotency_required, idempotency_strategy,
    permissions, resources, approval_required,
    input_schema, output_schema, manifest_hash, promotion_stage, image_digest
) VALUES (
    '00000000-0000-0000-0000-0000000000c4',
    '00000000-0000-0000-0000-0000000000b1',
    '1.0.2', 1, 'none', true, 'caller_key',
    '{}'::jsonb, '{}'::jsonb, false,
    '{}'::jsonb, '{}'::jsonb, repeat('0', 64), 'promoted',
    'sha256:' || repeat('a', 64)
);

DO $$
BEGIN
    RAISE NOTICE 'promoted tool version with a valid digest: accepted';
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

-- 14. The >256 KiB offload rule is enforced by the type, not by convention  [V12]
DO $$
BEGIN
    BEGIN
        INSERT INTO continuum.events (
            event_id, workspace_id, event_type, schema_version,
            aggregate_type, aggregate_id, actor_type, payload, occurred_at
        ) VALUES (
            gen_random_uuid(), '00000000-0000-0000-0000-0000000000aa',
            'OversizeEvent', 1, 'workspace',
            '00000000-0000-0000-0000-0000000000aa', 'system',
            jsonb_build_object('blob', repeat('x', 300000)), now()
        );
        RAISE EXCEPTION 'a >256 KiB payload was accepted inline';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'oversized JSONB payload rejected: enforced';
    END;
END
$$;

-- 15. Lexical retrieval actually has something to match against        [DERIVED]
INSERT INTO continuum.memories (id, workspace_id, memory_type, content, content_hash)
VALUES ('00000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000000aa',
        'semantic', 'the falsifier caught a seeded hypothesis', repeat('0', 64));

DO $$
DECLARE hits integer;
BEGIN
    SELECT count(*) INTO hits
      FROM continuum.memories
     WHERE workspace_id = '00000000-0000-0000-0000-0000000000aa'
       AND search_tsv @@ to_tsquery('english', 'falsifier & hypothesis');
    IF hits <> 1 THEN
        RAISE EXCEPTION 'generated search_tsv did not match (% hits)', hits;
    END IF;
    RAISE NOTICE 'generated search_tsv is populated and matches';
END
$$;

-- 16. The event hash chain is computed server-side and is reconstructible [DERIVED]
DO $$
DECLARE
    i integer;
    total integer;
    broken integer;
    ordered integer;
BEGIN
    -- three events in ONE transaction: the case that defeats ingested_at ordering
    FOR i IN 1..3 LOOP
        INSERT INTO continuum.events (
            event_id, workspace_id, event_type, schema_version,
            aggregate_type, aggregate_id, actor_type, payload, occurred_at
        ) VALUES (
            gen_random_uuid(), '00000000-0000-0000-0000-0000000000aa',
            'ChainEvent', 1, 'workspace',
            '00000000-0000-0000-0000-0000000000aa', 'system',
            jsonb_build_object('seq', i), now()
        );
    END LOOP;

    SELECT count(*) INTO total
      FROM continuum.events
     WHERE workspace_id = '00000000-0000-0000-0000-0000000000aa';

    -- every non-genesis event must chain to the event immediately before it
    -- in sequence order; this is what a random-uuid tiebreak cannot guarantee
    SELECT count(*) INTO broken
      FROM (
        SELECT event_hash, previous_hash,
               lag(event_hash) OVER (ORDER BY sequence) AS prior
          FROM continuum.events
         WHERE workspace_id = '00000000-0000-0000-0000-0000000000aa'
      ) c
     WHERE c.prior IS NOT NULL AND c.previous_hash IS DISTINCT FROM c.prior;

    IF broken <> 0 THEN
        RAISE EXCEPTION 'hash chain does not follow sequence order (% breaks)', broken;
    END IF;

    SELECT count(*) INTO ordered
      FROM continuum.events
     WHERE workspace_id = '00000000-0000-0000-0000-0000000000aa'
       AND event_hash IS NOT NULL;
    IF ordered <> total THEN
        RAISE EXCEPTION 'some events have no computed hash';
    END IF;

    RAISE NOTICE 'hash chain: % events, computed server-side, follows sequence order', total;
END
$$;

-- 17. A caller cannot write an event whose previous_hash contradicts the chain [DERIVED]
DO $$
BEGIN
    BEGIN
        INSERT INTO continuum.events (
            event_id, workspace_id, event_type, schema_version,
            aggregate_type, aggregate_id, actor_type, payload,
            previous_hash, occurred_at
        ) VALUES (
            gen_random_uuid(), '00000000-0000-0000-0000-0000000000aa',
            'ForgedEvent', 1, 'workspace',
            '00000000-0000-0000-0000-0000000000aa', 'system',
            '{}'::jsonb, repeat('f', 64), now()
        );
        RAISE EXCEPTION 'an event with a forged previous_hash was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'forged previous_hash rejected: enforced';
    END;
END
$$;

-- 18. TRUNCATE is rejected. Assertion 6 covers UPDATE and DELETE only, and
--     TRUNCATE bypasses row-level triggers entirely, so append-only is not
--     actually established without this. [DERIVED]
DO $$
BEGIN
    BEGIN
        TRUNCATE continuum.events;
        RAISE EXCEPTION 'TRUNCATE on the event store was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'TRUNCATE on the event store was accepted' THEN
            RAISE;
        END IF;
        RAISE NOTICE 'TRUNCATE on the event store rejected: enforced';
    END;
END
$$;

-- 19. The stored hash is reproducible by an independent verifier running under
--     a different session TimeZone. This re-implements the canonicalisation
--     documented in artifact section 4.2 and checks it against what the trigger
--     actually wrote, so the document and the schema cannot drift apart
--     silently. [DERIVED]
DO $$
DECLARE
    row_       continuum.events%ROWTYPE;
    recomputed char(64);
BEGIN
    SET LOCAL TimeZone = 'America/New_York';

    SELECT * INTO row_
      FROM continuum.events
     WHERE workspace_id = '00000000-0000-0000-0000-0000000000aa'
     ORDER BY sequence DESC
     LIMIT 1;

    recomputed := encode(sha256(convert_to(jsonb_build_object(
        'hash_version',        row_.hash_version,
        'sequence',            row_.sequence,
        'event_id',            row_.event_id,
        'workspace_id',        row_.workspace_id,
        'run_id',              row_.run_id,
        'event_type',          row_.event_type,
        'schema_version',      row_.schema_version,
        'aggregate_type',      row_.aggregate_type,
        'aggregate_id',        row_.aggregate_id,
        'causation_event_id',  row_.causation_event_id,
        'correlation_id',      row_.correlation_id,
        'actor_type',          row_.actor_type,
        'actor_id',            row_.actor_id,
        'trace_id',            row_.trace_id,
        'payload',             row_.payload,
        'payload_artifact_id', row_.payload_artifact_id,
        'previous_hash',       row_.previous_hash,
        'occurred_at',
            to_char(row_.occurred_at AT TIME ZONE 'UTC',
                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )::text, 'UTF8')), 'hex');

    IF recomputed IS DISTINCT FROM row_.event_hash THEN
        RAISE EXCEPTION 'hash is not reproducible under a different TimeZone: % <> %',
            recomputed, row_.event_hash;
    END IF;

    RAISE NOTICE 'event hash reproducible by an independent verifier under a non-UTC TimeZone';
END
$$;

-- 20. The offloaded-payload reference is covered by the hash. Repointing
--     payload_artifact_id at a different artifact must change event_hash,
--     otherwise the chain cannot detect that substitution. [DERIVED]
DO $$
DECLARE
    with_ref    char(64);
    with_other  char(64);
    base        jsonb;
BEGIN
    SELECT jsonb_build_object('payload_artifact_id',
                              '00000000-0000-0000-0000-0000000000c1'::uuid)
      INTO base;
    with_ref   := encode(sha256(convert_to(base::text, 'UTF8')), 'hex');
    with_other := encode(sha256(convert_to(
        jsonb_build_object('payload_artifact_id',
                           '00000000-0000-0000-0000-0000000000c2'::uuid)::text,
        'UTF8')), 'hex');

    IF with_ref = with_other THEN
        RAISE EXCEPTION 'payload_artifact_id does not affect the canonical form';
    END IF;

    PERFORM 1
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'continuum'
        AND p.proname = 'events_prepare_hash'
        AND pg_get_functiondef(p.oid) LIKE '%payload_artifact_id%';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'events_prepare_hash does not hash payload_artifact_id';
    END IF;

    RAISE NOTICE 'offloaded payload reference is covered by the event hash';
END
$$;

-- 21. The ordering value is not handed out before the chain lock. A default on
--     continuum.events.sequence would be evaluated while the tuple is built,
--     which is before the BEFORE INSERT trigger acquires the per-workspace
--     advisory lock -- the window in which two writers can interleave into a
--     backward link. [DERIVED]
DO $$
DECLARE
    has_default boolean;
BEGIN
    SELECT a.atthasdef INTO has_default
      FROM pg_attribute a
     WHERE a.attrelid = 'continuum.events'::regclass
       AND a.attname  = 'sequence';

    IF has_default THEN
        RAISE EXCEPTION
            'continuum.events.sequence still has a column default; the ordering '
            'value is allocated outside the advisory lock';
    END IF;

    PERFORM 1
       FROM pg_indexes
      WHERE schemaname = 'continuum'
        AND tablename  = 'events'
        AND indexdef LIKE '%(workspace_id, sequence DESC)%';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no (workspace_id, sequence DESC) index for the chain-head lookup';
    END IF;

    RAISE NOTICE 'ordering value allocated under the chain lock; chain-head lookup indexed';
END
$$;

-- 22. The hash layout is versioned per row, and the version is itself hashed.
--     Without this the canonicalisation is a one-way door: any later change
--     invalidates every chain ever written. ADR-0002. [DECISION: ADR-0002]
DO $$
DECLARE
    has_default  boolean;
    versions     integer;
    nulls        integer;
BEGIN
    -- Written by the trigger, never defaulted, so the value cannot disagree
    -- with the code that computed the hash beside it.
    SELECT a.atthasdef INTO has_default
      FROM pg_attribute a
     WHERE a.attrelid = 'continuum.events'::regclass
       AND a.attname  = 'hash_version';
    IF has_default THEN
        RAISE EXCEPTION 'hash_version has a column default; it must be set by the hash trigger';
    END IF;

    SELECT count(DISTINCT hash_version), count(*) FILTER (WHERE hash_version IS NULL)
      INTO versions, nulls
      FROM continuum.events;
    IF nulls <> 0 THEN
        RAISE EXCEPTION '% events carry no hash_version', nulls;
    END IF;
    IF versions <> 1 THEN
        RAISE EXCEPTION 'expected one hash layout in use, found %', versions;
    END IF;

    -- Covered by the hash, so flipping the column cannot make a verifier apply
    -- the wrong layout to a row.
    PERFORM 1
       FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'continuum'
        AND p.proname = 'events_prepare_hash'
        AND pg_get_functiondef(p.oid) LIKE '%''hash_version'',%';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'events_prepare_hash does not hash hash_version';
    END IF;

    RAISE NOTICE 'hash layout is versioned per row and the version is hashed';
END
$$;

-- A built-in agent: workspace_id IS NULL means shared by every tenant.
-- Assertion 13 checks only that the policy TEXT mentions IS NULL; assertion 23
-- below reads this row as an ordinary tenant, which is the actual claim.
INSERT INTO continuum.agents (id, workspace_id, name, role)
VALUES ('00000000-0000-0000-0000-0000000000d1', NULL, 'builtin-falsifier', 'falsifier');

-- 23. Tenant isolation is enforced in BEHAVIOUR, not merely configured.
--
--     Assertion 5 checks pg_class.relrowsecurity and relforcerowsecurity: it
--     proves RLS is switched on, not that any policy does anything. A policy of
--     `USING (workspace_id = workspace_id)` isolates nothing and still passes
--     assertion 5. Nor would running these checks as the superuser help --
--     superusers bypass RLS entirely, FORCE included, so the predicate is never
--     evaluated. This assertion therefore drops to continuum_app, the role the
--     application actually uses, which is NOLOGIN NOBYPASSRLS.
--
--     v1.2 states the hard gate as zero cross-workspace access. This is the
--     assertion that tests it. [V12]
DO $$
DECLARE
    ws_a       constant uuid := '00000000-0000-0000-0000-0000000000aa';
    ws_b       constant uuid := '00000000-0000-0000-0000-0000000000bb';
    seen_own   integer;
    seen_other integer;
    seen_unset integer;
    builtin    integer;
BEGIN
    SET LOCAL ROLE continuum_app;

    PERFORM set_config('app.workspace_id', ws_a::text, true);

    SELECT count(*) INTO seen_own
      FROM continuum.memories WHERE workspace_id = ws_a;
    IF seen_own = 0 THEN
        RAISE EXCEPTION 'tenant cannot see its own rows; the policy is too strict';
    END IF;

    SELECT count(*) INTO seen_other
      FROM continuum.memories WHERE workspace_id = ws_b;
    IF seen_other <> 0 THEN
        RAISE EXCEPTION
            'cross-workspace read: % row(s) belonging to another tenant are visible',
            seen_other;
    END IF;

    -- WITH CHECK must refuse a row planted into someone else's workspace.
    BEGIN
        INSERT INTO continuum.memories
            (id, workspace_id, memory_type, content, content_hash)
        VALUES (gen_random_uuid(), ws_b, 'semantic', 'planted', repeat('c', 64));
        RAISE EXCEPTION 'cross-workspace write accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    -- Built-in agents (workspace_id IS NULL) stay readable to every tenant.
    SELECT count(*) INTO builtin
      FROM continuum.agents WHERE workspace_id IS NULL;
    IF builtin = 0 THEN
        RAISE EXCEPTION 'built-in agents are invisible to a tenant under RLS';
    END IF;

    -- Fail closed: no tenant context must expose nothing, not everything.
    PERFORM set_config('app.workspace_id', '', true);
    SELECT count(*) INTO seen_unset FROM continuum.memories;
    IF seen_unset <> 0 THEN
        RAISE EXCEPTION
            'unset tenant context exposed % row(s); RLS is not failing closed',
            seen_unset;
    END IF;

    RAISE NOTICE
        'tenant isolation enforced as continuum_app: own rows only, cross-tenant write rejected, fails closed';
END
$$;

-- 24. Erasure is a maintenance duty, and it is still tenant-scoped.
--
--     ADR-0003: the application role never hard-deletes; continuum_maintenance
--     does, and is NOBYPASSRLS like every other role, so a purge runs inside a
--     tenant context rather than sweeping across workspaces. A grant alone would
--     not establish that -- this exercises all four halves of the claim.
--     [DECISION: ADR-0003]
DO $$
DECLARE
    ws_a constant uuid := '00000000-0000-0000-0000-0000000000aa';
    ws_b constant uuid := '00000000-0000-0000-0000-0000000000bb';
    doomed uuid := gen_random_uuid();
    survivor_b integer;
    removed integer;
BEGIN
    INSERT INTO continuum.memories (id, workspace_id, memory_type, content, content_hash)
    VALUES (doomed, ws_a, 'semantic', 'to be erased', repeat('e', 64));

    -- 1. the application role must NOT be able to delete
    SET LOCAL ROLE continuum_app;
    PERFORM set_config('app.workspace_id', ws_a::text, true);
    BEGIN
        DELETE FROM continuum.memories WHERE id = doomed;
        RAISE EXCEPTION 'continuum_app was able to hard-delete a row';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    RESET ROLE;

    -- 2. the maintenance role must be able to, within its tenant context
    SET LOCAL ROLE continuum_maintenance;
    PERFORM set_config('app.workspace_id', ws_a::text, true);
    DELETE FROM continuum.memories WHERE id = doomed;
    GET DIAGNOSTICS removed = ROW_COUNT;
    IF removed <> 1 THEN
        RAISE EXCEPTION 'continuum_maintenance could not erase a row in its own workspace';
    END IF;

    -- 3. and must NOT reach another workspace's rows: RLS still applies to it
    DELETE FROM continuum.memories WHERE workspace_id = ws_b;
    GET DIAGNOSTICS removed = ROW_COUNT;
    IF removed <> 0 THEN
        RAISE EXCEPTION
            'continuum_maintenance deleted % row(s) from another workspace', removed;
    END IF;
    RESET ROLE;

    SELECT count(*) INTO survivor_b
      FROM continuum.memories WHERE workspace_id = ws_b;
    IF survivor_b = 0 THEN
        RAISE EXCEPTION 'tenant B rows did not survive a tenant A purge';
    END IF;

    RAISE NOTICE
        'erasure is maintenance-only and tenant-scoped: app denied, maintenance erased 1 row in its own workspace, other tenant untouched';
END
$$;

-- 25. The audit log is not erasable, by anyone. ADR-0003 excludes events from
--     the maintenance DELETE grant precisely because the append-only trigger
--     would reject it anyway; a grant that cannot be exercised reads as
--     permission and is worse than none. [DERIVED]
DO $$
DECLARE
    has_delete boolean;
BEGIN
    SELECT bool_or(privilege_type = 'DELETE') INTO has_delete
      FROM information_schema.role_table_grants
     WHERE table_schema = 'continuum'
       AND table_name IN ('events', 'workspaces')
       AND grantee = 'continuum_maintenance';
    IF coalesce(has_delete, false) THEN
        RAISE EXCEPTION
            'continuum_maintenance holds DELETE on events or workspaces; the '
            'append-only trigger would reject it, so the grant is a lie';
    END IF;

    RAISE NOTICE 'audit log and tenant root are excluded from the erasure grant';
END
$$;

SELECT 'DERIVED CORE SCHEMA VERIFICATION PASSED' AS result;
