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
      -- [DECISION] not workspace-scoped: users and models are global reference
      -- data; event_schemas is a global contract registry (ADR-0004). A
      -- per-tenant event catalogue would let one tenant declare types the
      -- validator applies differently for another, which is the opposite of
      -- what the registry is for.
      AND c.relname NOT IN ('users','models','event_schemas')
      AND (c.relrowsecurity IS FALSE OR c.relforcerowsecurity IS FALSE);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'RLS not enabled/forced on: %', bad;
    END IF;
    RAISE NOTICE 'RLS enabled and forced on all tenant-scoped tables';
END
$$;

-- Test event types. The registry ships empty and fails closed (ADR-0004), so
-- every type these assertions write must be registered first. That the fixtures
-- have to exist at all is the mechanism working.
INSERT INTO continuum.event_schemas (event_type, schema_version, allowed_keys, description)
VALUES
    ('VerifyEvent',     1, ARRAY['note'],       'append-only checks'),
    ('OversizeEvent',   1, ARRAY['blob'],       'payload bound check'),
    ('ChainEvent',      1, ARRAY['seq'],        'hash chain ordering'),
    ('ForgedEvent',     1, ARRAY['note'],       'forged previous_hash check');

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

-- 14. The event payload bound is enforced by the type, not by convention
--     [V12] offload rule, [DECISION: ADR-0004] the 8 KiB event bound
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
        RAISE EXCEPTION 'an oversized payload was accepted inline';
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

-- 24. Nothing deletes a domain row. v1.2 states the memory lifecycle as
--     stateful invalidation -- durable -> invalidated -> superseded_by -- and
--     says it "preserves historical reasoning", so removal contradicts the
--     design rather than merely exceeding least privilege.
--
--     Tested behaviourally for the application role, and by effective
--     privilege for every operational role: has_table_privilege, not
--     role_table_grants, so a DELETE inherited from another role or granted to
--     PUBLIC is caught. [V12] lifecycle, [DECISION: ADR-0003] enforcement
DO $$
DECLARE
    ws_a constant uuid := '00000000-0000-0000-0000-0000000000aa';
    r    text;
    t    text;
    held text[] := ARRAY[]::text[];
BEGIN
    SET LOCAL ROLE continuum_app;
    PERFORM set_config('app.workspace_id', ws_a::text, true);
    BEGIN
        DELETE FROM continuum.memories WHERE workspace_id = ws_a;
        RAISE EXCEPTION 'continuum_app deleted a domain row';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    RESET ROLE;

    FOREACH r IN ARRAY ARRAY['continuum_app','continuum_maintenance'] LOOP
        FOREACH t IN ARRAY ARRAY[
            'workspace_members','runs','artifacts','agents','agent_versions',
            'model_metrics','evidence','claims','claim_evidence','memories',
            'memory_embeddings','memory_edges','failures','tools','tool_versions',
            'tool_executions','evaluations','evaluation_results','mutations',
            'mutation_evaluations','cost_events','events','workspaces','users','models'
        ] LOOP
            IF has_table_privilege(r, 'continuum.' || t, 'DELETE') THEN
                held := held || (r || '.' || t);
            END IF;
        END LOOP;
    END LOOP;

    IF cardinality(held) > 0 THEN
        RAISE EXCEPTION
            'a role holds effective DELETE on a domain table: %; v1.2 supersedes '
            'rather than deletes', held;
    END IF;

    RAISE NOTICE
        'no operational role can delete a domain row; supersession is the lifecycle';
END
$$;

-- 25. The one deletion mechanism v1.2 DOES specify is modelled: artifact
--     retention. Bulk content lives in object storage and is governed by a
--     retention class and an optional expiry, two of whose classes exist to
--     prevent removal. The lifecycle that acts on these is not implemented yet
--     (ADR-0003); this asserts the contract it will act on has not drifted.
--     [V12] artifact manifest
DO $$
DECLARE
    classes text[];
    coltype text;
    nullable text;
BEGIN
    SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) INTO classes
      FROM pg_enum e
      JOIN pg_type ty ON ty.oid = e.enumtypid
      JOIN pg_namespace n ON n.oid = ty.typnamespace
     WHERE n.nspname = 'continuum' AND ty.typname = 'retention_class';

    IF classes IS DISTINCT FROM
       ARRAY['ephemeral','standard','durable','immutable','legal_hold'] THEN
        RAISE EXCEPTION 'retention_class drifted from the v1.2 manifest: %', classes;
    END IF;

    SELECT c.data_type, c.is_nullable INTO coltype, nullable
      FROM information_schema.columns c
     WHERE c.table_schema = 'continuum' AND c.table_name = 'artifacts'
       AND c.column_name = 'delete_after';
    IF coltype IS DISTINCT FROM 'timestamp with time zone' OR nullable <> 'YES' THEN
        RAISE EXCEPTION
            'artifacts.delete_after must be a nullable timestamptz, got % (nullable %)',
            coltype, nullable;
    END IF;

    -- legal_hold and immutable must be expressible without an expiry, or the
    -- classes that exist to prevent deletion could not be represented.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='continuum' AND table_name='artifacts'
           AND column_name='retention_class' AND is_nullable='YES'
    ) THEN
        RAISE EXCEPTION 'artifacts.retention_class must be NOT NULL';
    END IF;

    RAISE NOTICE
        'artifact retention contract intact: five v1.2 classes, nullable delete_after';
END
$$;

-- 26. The event payload shape is closed, and fails closed.
--
--     v1.2 bans raw prompts, raw source bodies, full personal data,
--     credentials, tokens, keys and private connector payloads from trace
--     attributes. Traces expire; this chain does not, so the same content is
--     kept out of events structurally. Three properties, each tested:
--
--       an unregistered event_type is rejected outright (opt-in catalogue);
--       a registered type carrying an unregistered key is rejected;
--       a registered type carrying only registered keys is accepted.
--
--     This closes the payload SHAPE. It cannot detect personal data inside a
--     registered key -- nothing in SQL can -- but it makes the key set
--     reviewed, bounded and testable. [DECISION: ADR-0004]
DO $$
DECLARE
    ws constant uuid := '00000000-0000-0000-0000-0000000000aa';
    accepted integer;
BEGIN
    -- 1. unregistered event type: fails closed
    BEGIN
        INSERT INTO continuum.events (
            event_id, workspace_id, event_type, schema_version,
            aggregate_type, aggregate_id, actor_type, payload, occurred_at
        ) VALUES (
            gen_random_uuid(), ws, 'UnregisteredEvent', 1, 'workspace',
            ws, 'system', jsonb_build_object('note', 'x'), now()
        );
        RAISE EXCEPTION 'an unregistered event_type was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- 2. registered type, unregistered key: rejected. This is the smuggling
    --    case -- the shape someone reaches for when they want the raw input
    --    in the log for debugging.
    BEGIN
        INSERT INTO continuum.events (
            event_id, workspace_id, event_type, schema_version,
            aggregate_type, aggregate_id, actor_type, payload, occurred_at
        ) VALUES (
            gen_random_uuid(), ws, 'VerifyEvent', 1, 'workspace',
            ws, 'system',
            jsonb_build_object('note', 'ok', 'raw_prompt', 'who is alice bell'),
            now()
        );
        RAISE EXCEPTION 'an unregistered payload key was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- 3. registered type, registered keys only: accepted, or the mechanism is
    --    simply a wall and the assertion above proves nothing useful.
    INSERT INTO continuum.events (
        event_id, workspace_id, event_type, schema_version,
        aggregate_type, aggregate_id, actor_type, payload, occurred_at
    ) VALUES (
        gen_random_uuid(), ws, 'VerifyEvent', 1, 'workspace',
        ws, 'system', jsonb_build_object('note', 'well-formed'), now()
    );
    GET DIAGNOSTICS accepted = ROW_COUNT;
    IF accepted <> 1 THEN
        RAISE EXCEPTION 'a well-formed registered payload was not accepted';
    END IF;

    RAISE NOTICE
        'event payload shape is closed: unregistered type and unregistered key rejected, well-formed accepted';
END
$$;

-- 27. Bulk content cannot be inlined into an event at all. The registry closes
--     the key set; this closes the volume, so a permitted key cannot become a
--     smuggling channel for a document. Offload goes to an artifact and is
--     referenced by payload_artifact_id. [DECISION: ADR-0004]
DO $$
DECLARE
    bound integer;
BEGIN
    SELECT octet_length(repeat('x', 9000)) INTO bound;

    BEGIN
        INSERT INTO continuum.events (
            event_id, workspace_id, event_type, schema_version,
            aggregate_type, aggregate_id, actor_type, payload, occurred_at
        ) VALUES (
            gen_random_uuid(), '00000000-0000-0000-0000-0000000000aa',
            'VerifyEvent', 1, 'workspace',
            '00000000-0000-0000-0000-0000000000aa', 'system',
            jsonb_build_object('note', repeat('x', 9000)), now()
        );
        RAISE EXCEPTION 'a % byte payload was accepted inline', bound;
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- The bound must be the event-specific one, not the general 256 KiB rule:
    -- events.payload carries the tighter domain.
    IF NOT EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'continuum' AND table_name = 'events'
           AND column_name = 'payload' AND domain_name = 'jsonb_8k'
    ) THEN
        RAISE EXCEPTION
            'events.payload does not carry the tightened event payload domain';
    END IF;

    RAISE NOTICE
        'bulk content cannot be inlined into an event; offload is by reference';
END
$$;

SELECT 'DERIVED CORE SCHEMA VERIFICATION PASSED' AS result;
