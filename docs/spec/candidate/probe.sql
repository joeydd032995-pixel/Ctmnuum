-- Empirical probe of two suspected defects in the candidate core DDL.
-- Each hypothesis is tested by executing it, not by reading the schema.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- H1: composite FK with ON DELETE SET NULL, where workspace_id is NOT NULL.
--     Deleting the parent should null only the child pointer. If PostgreSQL
--     nulls every referencing column, workspace_id NOT NULL rejects the delete.
-- ---------------------------------------------------------------------------

INSERT INTO continuum.workspaces (id, slug, name)
VALUES ('00000000-0000-0000-0000-00000000aaaa', 'probe-ws', 'Probe Workspace');

INSERT INTO continuum.runs (id, workspace_id, objective)
VALUES ('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000aaaa',
        'probe run');

INSERT INTO continuum.artifacts (
    id, workspace_id, run_id, kind, media_type, byte_length, sha256,
    storage_bucket, storage_key, kms_key_arn, classification,
    retention_class, producer_component, producer_version
) VALUES (
    '00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000aaaa',
    '00000000-0000-0000-0000-00000000a001', 'probe', 'text/plain', 10, repeat('0',64),
    'probe-bucket', 'probe/key', 'arn:aws:kms:us-east-1:1:key/abc', 'internal',
    'standard', 'probe', '1.0.0'
);

DO $$
BEGIN
    BEGIN
        DELETE FROM continuum.runs
        WHERE id = '00000000-0000-0000-0000-00000000a001';
        RAISE NOTICE 'H1 RESULT: delete SUCCEEDED -- ON DELETE SET NULL works here';
    EXCEPTION
        WHEN not_null_violation THEN
            RAISE NOTICE 'H1 RESULT: CONFIRMED DEFECT -- not_null_violation: %', SQLERRM;
        WHEN OTHERS THEN
            RAISE NOTICE 'H1 RESULT: other error [%] %', SQLSTATE, SQLERRM;
    END;
END
$$;

-- ---------------------------------------------------------------------------
-- H2: event chain ordering within a single transaction. ingested_at defaults to
--     now() (transaction timestamp), so three events inserted together tie, and
--     the chain-head query falls back to a random uuid.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    i integer;
BEGIN
    FOR i IN 1..3 LOOP
        INSERT INTO continuum.events (
            workspace_id, event_type, schema_version, aggregate_type,
            aggregate_id, correlation_id, actor_type, payload, occurred_at
        ) VALUES (
            '00000000-0000-0000-0000-00000000aaaa', 'ProbeEvent', 1, 'workspace',
            '00000000-0000-0000-0000-00000000aaaa',
            '00000000-0000-0000-0000-00000000c001', 'system',
            jsonb_build_object('seq', i), now()
        );
    END LOOP;
END
$$;

DO $$
DECLARE
    total integer;
    distinct_ingested integer;
    broken integer;
BEGIN
    SELECT count(*), count(DISTINCT ingested_at)
      INTO total, distinct_ingested
      FROM continuum.events
     WHERE workspace_id = '00000000-0000-0000-0000-00000000aaaa';

    -- a well-formed chain: every event except the genesis has a previous_hash
    -- that equals some other event's event_hash in the same workspace
    SELECT count(*) INTO broken
      FROM continuum.events e
     WHERE e.workspace_id = '00000000-0000-0000-0000-00000000aaaa'
       AND e.previous_hash IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM continuum.events p
            WHERE p.workspace_id = e.workspace_id
              AND p.event_hash = e.previous_hash);

    RAISE NOTICE 'H2 RESULT: % events, % distinct ingested_at values, % dangling previous_hash',
        total, distinct_ingested, broken;

    IF distinct_ingested < total THEN
        RAISE NOTICE 'H2 RESULT: CONFIRMED AMBIGUITY -- ingested_at ties, chain order depends on random uuid';
    ELSE
        RAISE NOTICE 'H2 RESULT: ingested_at values are distinct; ordering is determinate here';
    END IF;
END
$$;

SELECT 'PROBE COMPLETE' AS result;
