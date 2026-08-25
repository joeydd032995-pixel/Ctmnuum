-- Continuum v1.2 — Core PostgreSQL DDL (DERIVED RECONSTRUCTION)
--
-- STATUS: DERIVED. THIS IS NOT RECOVERED v1.2 SOURCE TEXT.
--
-- Companion to docs/spec/Continuum_v1.2_Core_Implementation_Artifact.derived.md,
-- which carries the full provenance tagging and the list of decisions still
-- requiring ADR approval. Provenance tags below use the same legend:
--
--   [V12]      stated directly in the v1.2 report
--   [V11]      carried from the v1.0/v1.1 predecessor architecture
--   [DERIVED]  inferred from a cited v1.2 invariant
--   [DECISION] no source support; requires ADR approval
--
-- This file exists to be executed, so that the reconstruction is verified to be
-- valid PostgreSQL 18 + pgvector rather than merely plausible prose. Applying it
-- does NOT adopt it as the production schema: FND-DB-DOMAIN remains blocked by
-- SRC-001 until the decisions in §8 of the companion document are approved.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. Schema, extensions, roles                       (approved under ADR-0001)
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS continuum;               -- [V12]
CREATE EXTENSION IF NOT EXISTS vector;               -- [V12]
CREATE EXTENSION IF NOT EXISTS citext;               -- [DECISION] case-insensitive email

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'continuum_app') THEN
        CREATE ROLE continuum_app NOLOGIN NOBYPASSRLS;           -- [V12] invariant
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'continuum_migration') THEN
        CREATE ROLE continuum_migration NOLOGIN NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'continuum_maintenance') THEN
        CREATE ROLE continuum_maintenance NOLOGIN NOBYPASSRLS;
    END IF;
END
$$;

-- [V12] transaction-scoped tenant context; fails closed when unset
CREATE OR REPLACE FUNCTION continuum.current_workspace_id()
RETURNS uuid LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT NULLIF(current_setting('app.workspace_id', true), '')::uuid;
$$;

-- ---------------------------------------------------------------------------
-- 2. Enumerated types
-- ---------------------------------------------------------------------------

CREATE TYPE continuum.claim_status AS ENUM (          -- [V11] ClaimStatus
    'supported', 'contested', 'inferred', 'unverified', 'falsified');

CREATE TYPE continuum.evidence_type AS ENUM (         -- [V11] EvidenceType
    'user', 'first_party', 'verified_connector',
    'public_source', 'experiment', 'tool_result');

CREATE TYPE continuum.memory_status AS ENUM (         -- [V12] lifecycle + invalidation
    'temporary', 'candidate', 'validated', 'durable', 'invalidated');

CREATE TYPE continuum.memory_type AS ENUM (           -- [DECISION]
    'semantic', 'episodic', 'procedural', 'failure');

CREATE TYPE continuum.artifact_classification AS ENUM (  -- [V12] artifact manifest
    'public', 'internal', 'confidential', 'restricted');

CREATE TYPE continuum.retention_class AS ENUM (       -- [V12] artifact manifest
    'ephemeral', 'standard', 'durable', 'immutable', 'legal_hold');

CREATE TYPE continuum.side_effect AS ENUM (           -- [V12] tool manifest
    'none', 'internal_write', 'reversible_external_write', 'irreversible_external_write');

CREATE TYPE continuum.idempotency_strategy AS ENUM (  -- [V12] tool manifest
    'none', 'caller_key', 'provider_key', 'database_dedup');

CREATE TYPE continuum.mutation_class AS ENUM (        -- [V12] Evolution section
    'agent', 'prompt', 'tool', 'workflow',
    'retrieval', 'model_route', 'policy', 'context_budget');

CREATE TYPE continuum.promotion_stage AS ENUM (       -- [DERIVED] from the v1.2 pipeline
    'proposed', 'quarantined', 'benchmarked', 'shadow',
    'canary', 'approved', 'promoted', 'rejected', 'rolled_back');

CREATE TYPE continuum.run_status AS ENUM (            -- [DECISION]
    'accepted', 'running', 'succeeded', 'failed', 'cancelled');

-- ---------------------------------------------------------------------------
-- 3. Tenancy and identity
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.users (
    id           uuid PRIMARY KEY,                                    -- [DERIVED]
    email        citext NOT NULL UNIQUE,                              -- [DECISION]
    display_name text,                                                -- [DECISION]
    status       text NOT NULL DEFAULT 'active',                      -- [DECISION]
    created_at   timestamptz NOT NULL DEFAULT now(),                  -- [V11]
    updated_at   timestamptz NOT NULL DEFAULT now()                   -- [DECISION]
);

CREATE TABLE continuum.workspaces (
    id         uuid PRIMARY KEY,                                      -- [V12]
    name       text NOT NULL,                                         -- [DECISION]
    plan_tier  text NOT NULL DEFAULT 'free'                           -- [V12] fairness weights per tier
        CHECK (plan_tier IN ('free','pro','team','enterprise','internal')),
    status     text NOT NULL DEFAULT 'active',                        -- [DECISION]
    created_at timestamptz NOT NULL DEFAULT now(),                    -- [V11]
    updated_at timestamptz NOT NULL DEFAULT now()                     -- [DECISION]
);

CREATE TABLE continuum.workspace_members (
    workspace_id uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    user_id      uuid NOT NULL REFERENCES continuum.users(id) ON DELETE CASCADE,
    role         text NOT NULL DEFAULT 'member'                       -- [DECISION]
        CHECK (role IN ('owner','admin','member','viewer')),
    created_at   timestamptz NOT NULL DEFAULT now(),                  -- [V11]
    PRIMARY KEY (workspace_id, user_id)                               -- [DERIVED]
);

-- ---------------------------------------------------------------------------
-- 4. Runs
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.runs (
    id              uuid PRIMARY KEY,                                 -- [V12]
    workspace_id    uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    created_by      uuid REFERENCES continuum.users(id),              -- [DECISION]
    status          continuum.run_status NOT NULL DEFAULT 'accepted', -- [DECISION]
    objective       text NOT NULL,                                    -- [DERIVED]
    depth           text NOT NULL DEFAULT 'standard'                  -- [V12] Deep/Critical named
        CHECK (depth IN ('quick','standard','deep','critical')),
    token_budget    integer CHECK (token_budget > 0 AND token_budget <= 200000),  -- [V12]
    budget_usd      numeric(12,6),                                    -- [V12] ModelRequest.budget_usd
    deadline_at     timestamptz,                                      -- [V12] ActivityContext.deadline_at
    workflow_id     text,                                             -- [DERIVED]
    workflow_run_id text,                                             -- [DERIVED]
    trace_id        char(32) CHECK (trace_id ~ '^[0-9a-f]{32}$'),     -- [V12] pattern
    started_at      timestamptz,                                      -- [DECISION]
    completed_at    timestamptz,                                      -- [DECISION]
    created_at      timestamptz NOT NULL DEFAULT now()                -- [V11]
);

CREATE INDEX runs_workspace_created_idx
    ON continuum.runs (workspace_id, created_at DESC);                -- [DERIVED]

-- ---------------------------------------------------------------------------
-- 5. Agents
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.agents (
    id           uuid PRIMARY KEY,                                    -- [V12]
    workspace_id uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    name         text NOT NULL,                                       -- [DECISION]
    role         text NOT NULL,                                       -- [V12] agent roles named
    status       text NOT NULL DEFAULT 'active',                      -- [DECISION]
    created_at   timestamptz NOT NULL DEFAULT now(),                  -- [V11]
    UNIQUE (workspace_id, name)                                       -- [DECISION]
);

CREATE TABLE continuum.agent_versions (
    id                 uuid PRIMARY KEY,                              -- [V12] agent_version_id
    agent_id           uuid NOT NULL REFERENCES continuum.agents(id) ON DELETE CASCADE,
    workspace_id       uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    version            integer NOT NULL,                              -- [DERIVED]
    prompt_hash        char(64) NOT NULL,                             -- [DERIVED] prompts are versioned
    prompt_artifact_id uuid,                                          -- [V12] >256 KiB to S3
    config             jsonb NOT NULL DEFAULT '{}'::jsonb,            -- [DECISION]
    output_schema_id   text,                                          -- [V12] ExecuteAgentInput
    status             continuum.promotion_stage NOT NULL DEFAULT 'promoted',  -- [DERIVED]
    created_at         timestamptz NOT NULL DEFAULT now(),            -- [V11]
    UNIQUE (agent_id, version)                                        -- [DERIVED]
);

-- ---------------------------------------------------------------------------
-- 6. Models
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.models (
    id           uuid PRIMARY KEY,                                    -- [V12]
    provider     text NOT NULL,                                       -- [V12] ModelResponse.provider
    model_id     text NOT NULL,                                       -- [V12] ModelResponse.model_id
    snapshot_id  text,                                                -- [V12] ModelResponse.snapshot_id
    profile      text CHECK (profile IN ('economical','high_reasoning','embedding')),  -- [V12]
    status       text NOT NULL DEFAULT 'active'                       -- [V12] hard router filter
        CHECK (status IN ('active','shadow','deprecated','disabled')),
    capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,                  -- [V12] capabilities()
    created_at   timestamptz NOT NULL DEFAULT now(),                  -- [V11]
    UNIQUE (provider, model_id, snapshot_id)                          -- [DERIVED]
);

CREATE TABLE continuum.model_metrics (
    id                uuid PRIMARY KEY,                               -- [V12]
    model_id          uuid NOT NULL REFERENCES continuum.models(id) ON DELETE CASCADE,
    workspace_id      uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    task_family       text NOT NULL,                                  -- [V12] ModelRequest.task_family
    window_start      timestamptz NOT NULL,                           -- [DECISION]
    window_end        timestamptz NOT NULL,                           -- [DECISION]
    sample_count      integer NOT NULL CHECK (sample_count >= 0),     -- [DECISION]
    success_rate      double precision CHECK (success_rate BETWEEN 0 AND 1),      -- [V12] Q
    calibration_error double precision CHECK (calibration_error >= 0),            -- [V12] ECE gate
    brier_score       double precision CHECK (brier_score >= 0),                  -- [V12] Brier gate
    p95_latency_ms    integer,                                        -- [V12] L
    availability      double precision CHECK (availability BETWEEN 0 AND 1),      -- [V12] A
    mean_cost_usd     numeric(12,6),                                  -- [V12] K
    created_at        timestamptz NOT NULL DEFAULT now()              -- [V11]
);

-- ---------------------------------------------------------------------------
-- 7. Claims and evidence                              [V11] typed source models
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.evidence (
    id                  uuid PRIMARY KEY,                             -- [V11] Evidence.id
    workspace_id        uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id              uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    type                continuum.evidence_type NOT NULL,             -- [V11]
    uri                 text,                                         -- [V11]
    content_hash        char(64) NOT NULL,                            -- [V11]
    observed_at         timestamptz NOT NULL,                         -- [V11]
    valid_from          timestamptz,                                  -- [V11]
    valid_until         timestamptz,                                  -- [V11]
    trust_score         double precision NOT NULL                     -- [V11] ge=0 le=1
        CHECK (trust_score BETWEEN 0 AND 1),
    payload             jsonb NOT NULL DEFAULT '{}'::jsonb,           -- [V11]
    payload_artifact_id uuid,                                         -- [V12] >256 KiB to S3
    trace_id            char(32),                                     -- [V11]
    created_at          timestamptz NOT NULL DEFAULT now()            -- [V11]
);

CREATE TABLE continuum.claims (
    id                       uuid PRIMARY KEY,                        -- [V11] Claim.id
    workspace_id             uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id                   uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    statement                text NOT NULL,                           -- [V11]
    status                   continuum.claim_status NOT NULL,         -- [V11]
    confidence               double precision NOT NULL                -- [V11] ge=0 le=1
        CHECK (confidence BETWEEN 0 AND 1),
    assumptions              text[] NOT NULL DEFAULT '{}',            -- [V11]
    falsification_conditions text[] NOT NULL DEFAULT '{}',            -- [V11]
    created_by_agent_version uuid REFERENCES continuum.agent_versions(id),  -- [V11]
    superseded_by            uuid REFERENCES continuum.claims(id),    -- [DERIVED]
    trace_id                 char(32),                                -- [V11]
    created_at               timestamptz NOT NULL DEFAULT now()       -- [V11]
);

CREATE TABLE continuum.claim_evidence (
    claim_id     uuid NOT NULL REFERENCES continuum.claims(id) ON DELETE CASCADE,
    evidence_id  uuid NOT NULL REFERENCES continuum.evidence(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    stance       text NOT NULL CHECK (stance IN ('supports','opposes')),  -- [V11]
    weight       double precision CHECK (weight BETWEEN 0 AND 1),     -- [DECISION]
    created_at   timestamptz NOT NULL DEFAULT now(),                  -- [V11]
    PRIMARY KEY (claim_id, evidence_id, stance)                       -- [DERIVED]
);

CREATE INDEX claim_evidence_evidence_idx
    ON continuum.claim_evidence (evidence_id);                        -- [DERIVED]

-- ---------------------------------------------------------------------------
-- 8. Memory
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.memories (
    id                  uuid PRIMARY KEY,                             -- [V12]
    workspace_id        uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    memory_type         continuum.memory_type NOT NULL,               -- [V12] selected in source query
    content             text NOT NULL,                                -- [V12]
    content_hash        char(64) NOT NULL,                            -- [V12] hash-mismatch gate
    content_artifact_id uuid,                                         -- [V12] >256 KiB to S3
    status              continuum.memory_status NOT NULL DEFAULT 'temporary',  -- [V12]
    invalidated_at      timestamptz,                                  -- [V12]
    superseded_by       uuid REFERENCES continuum.memories(id),       -- [V12]
    valid_from          timestamptz,                                  -- [V12]
    valid_until         timestamptz,                                  -- [V12]
    freshness_class     text NOT NULL DEFAULT 'slow_changing'         -- [V12] half-life classes
        CHECK (freshness_class IN ('highly_dynamic','dynamic','slow_changing','stable')),
    salience            double precision CHECK (salience BETWEEN 0 AND 1),  -- [V12]
    utility             double precision CHECK (utility BETWEEN 0 AND 1),   -- [V12]
    source_run_id       uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,  -- [DERIVED]
    search_tsv          tsvector,                                     -- [V12] FTS named
    trace_id            char(32),                                     -- [V11]
    created_at          timestamptz NOT NULL DEFAULT now()            -- [V11]
);

CREATE INDEX memories_fts_idx ON continuum.memories USING gin (search_tsv);   -- [DERIVED]
CREATE INDEX memories_workspace_status_idx
    ON continuum.memories (workspace_id, status)
    WHERE invalidated_at IS NULL;                                     -- [DERIVED]

-- [V12] reproduced verbatim from the one complete DDL block in the source
CREATE TABLE continuum.memory_embeddings (
    memory_id uuid NOT NULL
        REFERENCES continuum.memories(id) ON DELETE CASCADE,
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    embedding_model text NOT NULL,
    embedding_version text NOT NULL DEFAULT 'v1',
    dimensions smallint NOT NULL DEFAULT 512
        CHECK (dimensions = 512),
    source_content_hash char(64) NOT NULL,
    embedding vector(512) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (
        memory_id,
        embedding_model,
        embedding_version
    )
);

CREATE INDEX memory_embeddings_hnsw_cosine_idx
ON continuum.memory_embeddings
USING hnsw (embedding vector_cosine_ops)
WITH (
    m = 16,
    ef_construction = 64
);

-- [V11] knowledge_edges shape, identical in v1.0 and v1.1
CREATE TABLE continuum.memory_edges (
    id           uuid PRIMARY KEY,
    workspace_id uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    source_type  text NOT NULL,
    source_id    uuid NOT NULL,
    relation     text NOT NULL,
    target_type  text NOT NULL,
    target_id    uuid NOT NULL,
    weight       double precision NOT NULL DEFAULT 1,
    valid_from   timestamptz,
    valid_until  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX memory_edges_source_idx
    ON continuum.memory_edges (workspace_id, source_type, source_id);  -- [DERIVED]
CREATE INDEX memory_edges_target_idx
    ON continuum.memory_edges (workspace_id, target_type, target_id);  -- [DERIVED]

-- ---------------------------------------------------------------------------
-- 9. Failures                                        [V11] FailureRecord model
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.failures (
    id                   uuid PRIMARY KEY,                            -- [V12]
    workspace_id         uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id               uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    task_type            text NOT NULL,                               -- [V11]
    observed_failure     text NOT NULL,                               -- [V11]
    expected_behavior    text NOT NULL,                               -- [V11]
    root_cause           text,                                        -- [V11] nullable
    contributing_factors text[] NOT NULL DEFAULT '{}',                -- [V11]
    missed_signals       text[] NOT NULL DEFAULT '{}',                -- [V11]
    corrective_rule      text,                                        -- [V11] nullable
    regression_test_id   text,                                        -- [V11] nullable
    severity             integer NOT NULL,                            -- [V11]
    trace_id             char(32),                                    -- [V11]
    created_at           timestamptz NOT NULL DEFAULT now()           -- [V11]
);

-- ---------------------------------------------------------------------------
-- 10. Tools                                          [V12] tool manifest schema
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.tools (
    id           uuid PRIMARY KEY,                                    -- [V12]
    workspace_id uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    name         text NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9._-]{2,127}$'),  -- [V12] verbatim
    purpose      text NOT NULL CHECK (length(purpose) >= 8),          -- [V12] minLength 8
    status       text NOT NULL DEFAULT 'active',                      -- [DECISION]
    created_at   timestamptz NOT NULL DEFAULT now(),                  -- [V11]
    UNIQUE (workspace_id, name)                                       -- [DERIVED]
);

CREATE TABLE continuum.tool_versions (
    id                   uuid PRIMARY KEY,                            -- [V12]
    tool_id              uuid NOT NULL REFERENCES continuum.tools(id) ON DELETE CASCADE,
    workspace_id         uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    version              text NOT NULL                                -- [V12] semver, verbatim
        CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
    risk_level           smallint NOT NULL CHECK (risk_level BETWEEN 0 AND 4),  -- [V12]
    side_effect          continuum.side_effect NOT NULL,              -- [V12]
    reversible           boolean,                                     -- [V12]
    idempotency_required boolean NOT NULL,                            -- [V12]
    idempotency_strategy continuum.idempotency_strategy NOT NULL,     -- [V12]
    permissions          jsonb NOT NULL,                              -- [V12]
    resources            jsonb NOT NULL,                              -- [V12]
    approval_required    boolean NOT NULL,                            -- [V12]
    input_schema         jsonb NOT NULL,                              -- [V12]
    output_schema        jsonb NOT NULL,                              -- [V12]
    provenance           jsonb,                                       -- [V12]
    image_digest         text,                                        -- [V12] digest gate
    manifest_hash        char(64) NOT NULL,                           -- [DERIVED]
    promotion_stage      continuum.promotion_stage NOT NULL DEFAULT 'proposed',  -- [V12]
    created_at           timestamptz NOT NULL DEFAULT now(),          -- [V11]
    UNIQUE (tool_id, version),                                        -- [DERIVED]
    CHECK (risk_level < 3 OR approval_required IS TRUE)               -- [V12] risk 3-4 need approval
);

CREATE TABLE continuum.tool_executions (
    id                 uuid PRIMARY KEY,                              -- [V12]
    workspace_id       uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    tool_version_id    uuid NOT NULL REFERENCES continuum.tool_versions(id),
    run_id             uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    idempotency_key    text NOT NULL,                                 -- [V12]
    status             text NOT NULL,                                 -- [DECISION]
    exit_code          integer,                                       -- [V12] ExecResult
    wall_ms            integer,                                       -- [V12]
    cpu_ms             integer,                                       -- [V12]
    max_rss_bytes      bigint,                                        -- [V12]
    stdout_artifact_id uuid,                                          -- [V12]
    stderr_artifact_id uuid,                                          -- [V12]
    approved_by        uuid REFERENCES continuum.users(id),           -- [V12] approval audit
    approved_at        timestamptz,                                   -- [V12]
    trace_id           char(32),                                      -- [V11]
    created_at         timestamptz NOT NULL DEFAULT now(),            -- [V11]
    UNIQUE (workspace_id, idempotency_key)   -- [DERIVED] enforces "0 duplicate effects"
);

-- ---------------------------------------------------------------------------
-- 11. Evaluations
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.evaluations (
    id            uuid PRIMARY KEY,                                   -- [V12]
    workspace_id  uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    suite         text NOT NULL,                                      -- [V12] suite names
    suite_version text NOT NULL,                                      -- [V12] evaluators versioned
    target_type   text NOT NULL,                                      -- [DERIVED]
    target_id     uuid NOT NULL,                                      -- [DERIVED]
    status        text NOT NULL DEFAULT 'pending',                    -- [DECISION]
    started_at    timestamptz,                                        -- [DECISION]
    completed_at  timestamptz,                                        -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now()                  -- [V11]
);

CREATE TABLE continuum.evaluation_results (
    id            uuid PRIMARY KEY,                                   -- [V12]
    evaluation_id uuid NOT NULL REFERENCES continuum.evaluations(id) ON DELETE CASCADE,
    workspace_id  uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    case_id       text NOT NULL,                                      -- [DERIVED]
    passed        boolean NOT NULL,                                   -- [DECISION]
    score         double precision,                                   -- [V12] continuum_eval_score
    metric_name   text NOT NULL DEFAULT 'primary',                    -- [DECISION]
    detail        jsonb NOT NULL DEFAULT '{}'::jsonb,                 -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now(),                 -- [V11]
    UNIQUE (evaluation_id, case_id, metric_name)                      -- [DERIVED]
);

-- ---------------------------------------------------------------------------
-- 12. Mutations
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.mutations (
    id             uuid PRIMARY KEY,                                  -- [V12]
    workspace_id   uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    class          continuum.mutation_class NOT NULL,                 -- [V12] verbatim
    parent_id      uuid REFERENCES continuum.mutations(id),           -- [V12] lineage gate
    target_type    text NOT NULL,                                     -- [DERIVED]
    target_id      uuid NOT NULL,                                     -- [DERIVED]
    hypothesis     text NOT NULL,                                     -- [V12] versioned hypotheses
    stage          continuum.promotion_stage NOT NULL DEFAULT 'proposed',  -- [V12]
    git_ref        text,                                              -- [V12] Git owns evolution
    approved_by    uuid REFERENCES continuum.users(id),               -- [V12] human promotion only
    approved_at    timestamptz,                                       -- [V12]
    rolled_back_at timestamptz,                                       -- [V12]
    created_at     timestamptz NOT NULL DEFAULT now(),                -- [V11]
    CHECK (stage <> 'promoted' OR approved_by IS NOT NULL)   -- [DERIVED] no autonomous promotion
);

CREATE TABLE continuum.mutation_evaluations (
    mutation_id        uuid NOT NULL REFERENCES continuum.mutations(id) ON DELETE CASCADE,
    evaluation_id      uuid NOT NULL REFERENCES continuum.evaluations(id) ON DELETE CASCADE,
    workspace_id       uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    arm                text NOT NULL CHECK (arm IN ('control','variant')),  -- [DERIVED]
    quality_delta_pp   double precision,                              -- [V12] >= -0.5 pp
    quality_ci_low_pp  double precision,                              -- [V12] 95% CI bound
    quality_ci_high_pp double precision,                              -- [V12]
    cost_delta_pct     double precision,                              -- [V12] >= 10% reduction
    latency_delta_pct  double precision,                              -- [V12] >= 30% reduction
    created_at         timestamptz NOT NULL DEFAULT now(),            -- [V11]
    PRIMARY KEY (mutation_id, evaluation_id, arm)                     -- [DERIVED]
);

-- ---------------------------------------------------------------------------
-- 13. Artifacts                                  [V12] artifact manifest schema
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.artifacts (
    id                  uuid PRIMARY KEY,                             -- [V12] artifact_id
    workspace_id        uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id              uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    kind                text NOT NULL,                                -- [V12]
    media_type          text NOT NULL,                                -- [V12]
    filename            text,                                         -- [V12] nullable
    byte_length         bigint NOT NULL CHECK (byte_length >= 0),     -- [V12] minimum 0
    sha256              char(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),  -- [V12] verbatim
    storage_provider    text NOT NULL DEFAULT 's3' CHECK (storage_provider = 's3'),  -- [V12] const
    storage_bucket      text NOT NULL,                                -- [V12]
    storage_key         text NOT NULL,                                -- [V12]
    storage_version_id  text,                                         -- [V12] nullable
    encryption_mode     text NOT NULL DEFAULT 'SSE-KMS'
        CHECK (encryption_mode = 'SSE-KMS'),                          -- [V12] const
    kms_key_arn         text NOT NULL,                                -- [V12] required
    classification      continuum.artifact_classification NOT NULL,   -- [V12]
    retention_class     continuum.retention_class NOT NULL,           -- [V12]
    delete_after        timestamptz,                                  -- [V12] nullable
    producer_component  text NOT NULL,                                -- [V12]
    producer_version    text NOT NULL,                                -- [V12]
    parent_artifact_ids uuid[] NOT NULL DEFAULT '{}',                 -- [V12]
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,           -- [V12]
    created_at          timestamptz NOT NULL DEFAULT now()            -- [V12] required
);

CREATE INDEX artifacts_sha_idx ON continuum.artifacts (workspace_id, sha256);  -- [DERIVED]

-- ---------------------------------------------------------------------------
-- 14. Cost                                                 [V12] cost model
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.cost_events (
    id                    uuid PRIMARY KEY,                           -- [V12]
    workspace_id          uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id                uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    provider              text NOT NULL,                              -- [V12]
    sku                   text NOT NULL,                              -- [V12]
    component             text NOT NULL                               -- [V12] COGS components
        CHECK (component IN ('model','tool_api','temporal','eks',
                             'sandbox','db','s3','network','observability')),
    quantity              numeric(20,6) NOT NULL,                     -- [V12]
    unit                  text NOT NULL,                              -- [V12]
    unit_price            numeric(20,10) NOT NULL,                    -- [V12]
    cost_usd              numeric(14,6) NOT NULL,                     -- [V12]
    price_catalog_version text NOT NULL,                              -- [V12] versioned catalog
    occurred_at           timestamptz NOT NULL,                       -- [V12]
    created_at            timestamptz NOT NULL DEFAULT now()          -- [V11]
);

CREATE INDEX cost_events_run_idx ON continuum.cost_events (run_id);   -- [DERIVED]
CREATE INDEX cost_events_workspace_time_idx
    ON continuum.cost_events (workspace_id, occurred_at DESC);        -- [DERIVED]

-- ---------------------------------------------------------------------------
-- 15. Event store                       [V12] fields, [V11] run_events ancestor
-- ---------------------------------------------------------------------------

CREATE TABLE continuum.events (
    sequence            bigserial PRIMARY KEY,                        -- [V11]
    event_id            uuid NOT NULL UNIQUE,                         -- [V12]/[V11]
    workspace_id        uuid NOT NULL REFERENCES continuum.workspaces(id),
    run_id              uuid REFERENCES continuum.runs(id),           -- [V12]
    event_type          text NOT NULL,                                -- [V12]
    schema_version      integer NOT NULL,                             -- [V12]/[V11]
    aggregate_type      text NOT NULL,                                -- [V12]
    aggregate_id        uuid NOT NULL,                                -- [V12]
    causation_event_id  uuid,                                         -- [V12]
    correlation_id      uuid,                                         -- [V12]
    actor_type          text NOT NULL,                                -- [V12]
    actor_id            uuid,                                         -- [V12]
    trace_id            char(32),                                     -- [V12]
    payload             jsonb NOT NULL,                               -- [V12]/[V11]
    payload_artifact_id uuid,                                         -- [V12] >256 KiB to S3
    previous_hash       char(64),                                     -- [V12]
    event_hash          char(64) NOT NULL,                            -- [V12]
    occurred_at         timestamptz NOT NULL,                         -- [V12]
    ingested_at         timestamptz NOT NULL DEFAULT now()            -- [V12]
);

CREATE INDEX events_run_idx ON continuum.events (run_id, sequence);   -- [V11]
CREATE INDEX events_aggregate_idx
    ON continuum.events (workspace_id, aggregate_type, aggregate_id, sequence);  -- [DERIVED]

-- [V12] append-only for application roles; [DERIVED] enforcement mechanism
CREATE OR REPLACE FUNCTION continuum.events_reject_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'continuum.events is append-only (attempted %)', TG_OP;
END;
$$;

CREATE TRIGGER events_append_only
    BEFORE UPDATE OR DELETE ON continuum.events
    FOR EACH ROW EXECUTE FUNCTION continuum.events_reject_mutation();

REVOKE UPDATE, DELETE, TRUNCATE ON continuum.events FROM continuum_app;
GRANT INSERT, SELECT ON continuum.events TO continuum_app;

-- ---------------------------------------------------------------------------
-- 16. Row Level Security                                               [V12]
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    t text;
    tenant_tables text[] := ARRAY[
        'workspace_members','runs','agents','agent_versions','model_metrics',
        'evidence','claims','claim_evidence','memories','memory_embeddings',
        'memory_edges','failures','tools','tool_versions','tool_executions',
        'evaluations','evaluation_results','mutations','mutation_evaluations',
        'artifacts','cost_events','events'
    ];
BEGIN
    FOREACH t IN ARRAY tenant_tables LOOP
        EXECUTE format('ALTER TABLE continuum.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE continuum.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format(
            'CREATE POLICY %I ON continuum.%I '
            'USING (workspace_id = continuum.current_workspace_id()) '
            'WITH CHECK (workspace_id = continuum.current_workspace_id())',
            t || '_tenant_isolation', t);
    END LOOP;
END
$$;

-- [DERIVED] workspaces is the tenant root: its own primary key is the tenant
-- discriminator, so it needs a policy on `id` rather than `workspace_id`.
ALTER TABLE continuum.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.workspaces FORCE  ROW LEVEL SECURITY;
CREATE POLICY workspaces_tenant_isolation ON continuum.workspaces
    USING (id = continuum.current_workspace_id())
    WITH CHECK (id = continuum.current_workspace_id());

-- [DECISION] users and models are not workspace-scoped; governed by grants.
REVOKE ALL ON SCHEMA continuum FROM PUBLIC;
GRANT USAGE ON SCHEMA continuum TO continuum_app;
GRANT USAGE, CREATE ON SCHEMA continuum TO continuum_migration;
GRANT USAGE ON SCHEMA continuum TO continuum_maintenance;
