/*
Continuum v1.2 — Derived Core PostgreSQL DDL
Recovery status: DERIVED REPLACEMENT FOR A LOST ARTIFACT
Target: PostgreSQL 18 + pgvector

This file does not claim to be the missing original artifact. It reconstructs
the 25-table core contract from the surviving v1.2 specification.

Directly specified by v1.2:
  - the 25 table names;
  - PostgreSQL 18, pgvector, workspace-scoped RLS, SET LOCAL app.workspace_id;
  - the event envelope and append-only/hash-chain requirements;
  - the memory_embeddings columns, 512 dimensions, and HNSW parameters;
  - memory lifecycle and stateful invalidation;
  - artifact manifest, classification, retention, SHA-256, and S3 references;
  - tool manifest/risk/approval requirements;
  - per-run direct-cost event fields.

Conservatively derived:
  - columns not enumerated in the surviving specification;
  - relational keys, tenant-consistency constraints, lifecycle checks;
  - operational indexes and immutable-ledger triggers.

Application contract:
  BEGIN;
  SET LOCAL app.workspace_id = '<workspace UUID>';
  -- tenant-scoped statements
  COMMIT;

The normal application role must not own these objects and must not have
BYPASSRLS. Migration/maintenance roles must be physically distinct.
*/

BEGIN;

CREATE SCHEMA IF NOT EXISTS continuum;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE DOMAIN continuum.jsonb_256k AS jsonb
CHECK (VALUE IS NULL OR octet_length(VALUE::text) <= 262144);

CREATE OR REPLACE FUNCTION continuum.current_workspace_id()
RETURNS uuid
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT nullif(current_setting('app.workspace_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION continuum.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION continuum.reject_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; % is forbidden', TG_TABLE_NAME, TG_OP
        USING ERRCODE = '55000';
END;
$$;

-- 1. users: global identities; tenant visibility is mediated by membership.
CREATE TABLE continuum.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_subject text NOT NULL UNIQUE,
    email text,
    display_name text,
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('invited', 'active', 'suspended', 'deleted')),
    metadata continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CHECK (email IS NULL OR email = lower(email)),
    CHECK ((status = 'deleted') = (deleted_at IS NOT NULL))
);

CREATE UNIQUE INDEX users_email_lower_uq
ON continuum.users (lower(email))
WHERE email IS NOT NULL AND deleted_at IS NULL;

-- 2. workspaces: tenant root.
CREATE TABLE continuum.workspaces (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug text NOT NULL UNIQUE
        CHECK (slug ~ '^[a-z0-9][a-z0-9-]{2,62}$'),
    name text NOT NULL CHECK (btrim(name) <> ''),
    plan text NOT NULL DEFAULT 'personal'
        CHECK (plan IN ('free', 'personal', 'pro', 'builder', 'team', 'enterprise', 'internal')),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('provisioning', 'active', 'suspended', 'closed')),
    created_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    monthly_budget_usd numeric(18,6)
        CHECK (monthly_budget_usd IS NULL OR monthly_budget_usd >= 0),
    metadata continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    closed_at timestamptz,
    UNIQUE (id, created_by_user_id),
    CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);

-- 3. workspace_members: user-to-tenant authorization relation.
CREATE TABLE continuum.workspace_members (
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    user_id uuid NOT NULL
        REFERENCES continuum.users(id) ON DELETE RESTRICT,
    role text NOT NULL
        CHECK (role IN ('owner', 'admin', 'builder', 'analyst', 'viewer')),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('invited', 'active', 'suspended', 'removed')),
    invited_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    invited_at timestamptz,
    joined_at timestamptz,
    removed_at timestamptz,
    metadata continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, user_id),
    CHECK (status <> 'active' OR joined_at IS NOT NULL),
    CHECK ((status = 'removed') = (removed_at IS NOT NULL))
);

CREATE INDEX workspace_members_user_idx
ON continuum.workspace_members (user_id, workspace_id)
WHERE status = 'active';

-- 4. runs: durable business/cognitive run identity; Temporal owns execution state.
CREATE TABLE continuum.runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    parent_run_id uuid,
    requested_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    temporal_workflow_id text,
    temporal_run_id text,
    objective text NOT NULL CHECK (btrim(objective) <> ''),
    analysis_mode text NOT NULL DEFAULT 'standard'
        CHECK (analysis_mode IN ('fast', 'standard', 'deep', 'critical')),
    status text NOT NULL DEFAULT 'accepted'
        CHECK (status IN ('accepted', 'running', 'waiting_approval', 'succeeded', 'failed', 'cancelled')),
    priority smallint NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    budget_usd numeric(18,6) CHECK (budget_usd IS NULL OR budget_usd >= 0),
    cost_usd numeric(18,6) NOT NULL DEFAULT 0 CHECK (cost_usd >= 0),
    trace_id char(32) CHECK (trace_id IS NULL OR trace_id ~ '^[0-9a-f]{32}$'),
    request continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    result_summary continuum.jsonb_256k,
    input_artifact_id uuid,
    output_artifact_id uuid,
    accepted_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, temporal_workflow_id),
    FOREIGN KEY (workspace_id, parent_run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    CHECK (completed_at IS NULL OR started_at IS NOT NULL),
    CHECK (completed_at IS NULL OR completed_at >= started_at)
);

CREATE INDEX runs_workspace_status_created_idx
ON continuum.runs (workspace_id, status, created_at DESC);

-- 5. artifacts: durable metadata for large bytes owned by S3.
CREATE TABLE continuum.artifacts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id uuid,
    parent_artifact_id uuid,
    kind text NOT NULL CHECK (btrim(kind) <> ''),
    media_type text NOT NULL CHECK (btrim(media_type) <> ''),
    filename text,
    byte_length bigint NOT NULL CHECK (byte_length >= 0),
    sha256 char(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    storage_provider text NOT NULL DEFAULT 's3' CHECK (storage_provider = 's3'),
    storage_bucket text NOT NULL CHECK (btrim(storage_bucket) <> ''),
    storage_key text NOT NULL CHECK (btrim(storage_key) <> ''),
    storage_version_id text,
    encryption_mode text NOT NULL DEFAULT 'SSE-KMS' CHECK (encryption_mode = 'SSE-KMS'),
    kms_key_arn text NOT NULL CHECK (kms_key_arn LIKE 'arn:%:kms:%'),
    classification text NOT NULL
        CHECK (classification IN ('public', 'internal', 'confidential', 'restricted')),
    retention_class text NOT NULL
        CHECK (retention_class IN ('ephemeral', 'standard', 'durable', 'immutable', 'legal_hold')),
    delete_after timestamptz,
    producer_component text NOT NULL,
    producer_version text NOT NULL,
    metadata continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    integrity_verified_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, storage_bucket, storage_key, storage_version_id),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, parent_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE SET NULL,
    CHECK (retention_class NOT IN ('immutable', 'legal_hold') OR delete_after IS NULL)
);

CREATE INDEX artifacts_workspace_run_created_idx
ON continuum.artifacts (workspace_id, run_id, created_at DESC);

CREATE INDEX artifacts_workspace_sha256_idx
ON continuum.artifacts (workspace_id, sha256);

ALTER TABLE continuum.runs
    ADD CONSTRAINT runs_input_artifact_fk
        FOREIGN KEY (workspace_id, input_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE SET NULL,
    ADD CONSTRAINT runs_output_artifact_fk
        FOREIGN KEY (workspace_id, output_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE SET NULL;

-- 6. agents: stable agent identity.
CREATE TABLE continuum.agents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    name text NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9._-]{2,127}$'),
    purpose text NOT NULL CHECK (char_length(purpose) >= 8),
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'active', 'paused', 'retired')),
    current_version_id uuid,
    created_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    metadata continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, name)
);

-- 7. agent_versions: immutable/versioned executable agent configuration.
CREATE TABLE continuum.agent_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    version text NOT NULL CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
    system_prompt_artifact_id uuid,
    model_policy continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    tool_permissions continuum.jsonb_256k NOT NULL DEFAULT '[]'::jsonb,
    output_schema continuum.jsonb_256k,
    configuration continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    content_sha256 char(64) NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    status text NOT NULL DEFAULT 'candidate'
        CHECK (status IN ('candidate', 'shadow', 'canary', 'active', 'retired', 'rejected')),
    created_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, agent_id, version),
    UNIQUE (workspace_id, agent_id, content_sha256),
    FOREIGN KEY (workspace_id, agent_id)
        REFERENCES continuum.agents(workspace_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, system_prompt_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE RESTRICT
);

ALTER TABLE continuum.agents
    ADD CONSTRAINT agents_current_version_fk
    FOREIGN KEY (workspace_id, current_version_id)
    REFERENCES continuum.agent_versions(workspace_id, id) ON DELETE SET NULL;

-- 8. models: workspace-approved provider/model routing catalog.
CREATE TABLE continuum.models (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    provider text NOT NULL,
    model_id text NOT NULL,
    snapshot_id text,
    routing_profile text,
    status text NOT NULL DEFAULT 'shadow'
        CHECK (status IN ('shadow', 'active', 'degraded', 'disabled', 'retired')),
    capabilities continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    data_policy continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    unit_pricing_version text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE NULLS NOT DISTINCT (workspace_id, provider, model_id, snapshot_id)
);

-- 9. model_metrics: calibrated, time-windowed routing evidence.
CREATE TABLE continuum.model_metrics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    model_id uuid NOT NULL,
    task_family text NOT NULL,
    window_start timestamptz NOT NULL,
    window_end timestamptz NOT NULL,
    sample_count integer NOT NULL CHECK (sample_count >= 0),
    success_rate numeric(7,6) CHECK (success_rate BETWEEN 0 AND 1),
    expected_calibration_error numeric(7,6)
        CHECK (expected_calibration_error BETWEEN 0 AND 1),
    brier_score numeric(7,6) CHECK (brier_score BETWEEN 0 AND 1),
    p50_latency_ms integer CHECK (p50_latency_ms >= 0),
    p95_latency_ms integer CHECK (p95_latency_ms >= 0),
    average_cost_usd numeric(18,9) CHECK (average_cost_usd >= 0),
    statistics continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, model_id, task_family, window_start, window_end),
    FOREIGN KEY (workspace_id, model_id)
        REFERENCES continuum.models(workspace_id, id) ON DELETE CASCADE,
    CHECK (window_end > window_start)
);

CREATE INDEX model_metrics_routing_idx
ON continuum.model_metrics (workspace_id, task_family, window_end DESC);

-- 10. evidence: sourced material; model output alone is not evidence.
CREATE TABLE continuum.evidence (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    run_id uuid,
    source_artifact_id uuid,
    evidence_type text NOT NULL,
    source_uri text,
    source_title text,
    source_locator continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    excerpt text,
    content_sha256 char(64) NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    provenance continuum.jsonb_256k NOT NULL,
    reliability_score numeric(7,6) CHECK (reliability_score BETWEEN 0 AND 1),
    captured_at timestamptz NOT NULL,
    valid_from timestamptz,
    valid_until timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, source_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE RESTRICT,
    CHECK (source_uri IS NOT NULL OR source_artifact_id IS NOT NULL),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from),
    CHECK (excerpt IS NULL OR octet_length(excerpt) <= 262144)
);

CREATE INDEX evidence_workspace_run_created_idx
ON continuum.evidence (workspace_id, run_id, created_at DESC);

CREATE INDEX evidence_workspace_hash_idx
ON continuum.evidence (workspace_id, content_sha256);

-- 11. claims: explicit propositions with calibrated confidence.
CREATE TABLE continuum.claims (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    run_id uuid,
    agent_version_id uuid,
    statement text NOT NULL CHECK (btrim(statement) <> ''),
    normalized_sha256 char(64) NOT NULL CHECK (normalized_sha256 ~ '^[0-9a-f]{64}$'),
    status text NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed', 'supported', 'contested', 'rejected', 'superseded')),
    confidence numeric(7,6) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    valid_from timestamptz,
    valid_until timestamptz,
    supersedes_claim_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, agent_version_id)
        REFERENCES continuum.agent_versions(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, supersedes_claim_id)
        REFERENCES continuum.claims(workspace_id, id) ON DELETE SET NULL,
    CHECK (supersedes_claim_id IS NULL OR status = 'superseded'),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from)
);

CREATE INDEX claims_workspace_run_status_idx
ON continuum.claims (workspace_id, run_id, status, created_at DESC);

CREATE INDEX claims_workspace_hash_idx
ON continuum.claims (workspace_id, normalized_sha256);

-- 12. claim_evidence: many-to-many provenance with support/contradiction.
CREATE TABLE continuum.claim_evidence (
    workspace_id uuid NOT NULL,
    claim_id uuid NOT NULL,
    evidence_id uuid NOT NULL,
    relation text NOT NULL
        CHECK (relation IN ('supports', 'contradicts', 'context')),
    strength numeric(7,6) NOT NULL DEFAULT 1 CHECK (strength BETWEEN 0 AND 1),
    rationale text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, claim_id, evidence_id, relation),
    FOREIGN KEY (workspace_id, claim_id)
        REFERENCES continuum.claims(workspace_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, evidence_id)
        REFERENCES continuum.evidence(workspace_id, id) ON DELETE CASCADE
);

CREATE INDEX claim_evidence_evidence_idx
ON continuum.claim_evidence (workspace_id, evidence_id, relation);

-- 13. memories: durable identity, temporal validity, stateful invalidation.
CREATE TABLE continuum.memories (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    run_id uuid,
    source_claim_id uuid,
    source_artifact_id uuid,
    memory_type text NOT NULL
        CHECK (memory_type IN ('semantic', 'episodic', 'procedural', 'failure')),
    status text NOT NULL DEFAULT 'temporary'
        CHECK (status IN ('temporary', 'candidate', 'validated', 'durable', 'invalidated')),
    content_text text NOT NULL CHECK (btrim(content_text) <> ''),
    content continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    content_sha256 char(64) NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
    freshness_class text NOT NULL DEFAULT 'dynamic'
        CHECK (freshness_class IN ('highly_dynamic', 'dynamic', 'slow_changing', 'stable')),
    salience numeric(7,6) NOT NULL DEFAULT 0.5 CHECK (salience BETWEEN 0 AND 1),
    utility numeric(7,6) NOT NULL DEFAULT 0.5 CHECK (utility BETWEEN 0 AND 1),
    valid_from timestamptz,
    valid_until timestamptz,
    invalidated_at timestamptz,
    invalidation_reason text,
    superseded_by_memory_id uuid,
    search_vector tsvector GENERATED ALWAYS AS
        (to_tsvector('english', coalesce(content_text, ''))) STORED,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, content_sha256, memory_type),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, source_claim_id)
        REFERENCES continuum.claims(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, source_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, superseded_by_memory_id)
        REFERENCES continuum.memories(workspace_id, id) ON DELETE SET NULL,
    CHECK (octet_length(content_text) <= 262144),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from),
    CHECK ((status = 'invalidated') = (invalidated_at IS NOT NULL)),
    CHECK (invalidated_at IS NULL OR invalidation_reason IS NOT NULL),
    CHECK (superseded_by_memory_id IS NULL OR status = 'invalidated')
);

CREATE INDEX memories_fts_idx
ON continuum.memories USING gin (search_vector);

CREATE INDEX memories_retrieval_filter_idx
ON continuum.memories (workspace_id, status, invalidated_at, valid_from, valid_until);

-- 14. memory_embeddings: exact v1.2 column contract.
CREATE TABLE continuum.memory_embeddings (
    memory_id uuid NOT NULL,
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    embedding_model text NOT NULL,
    embedding_version text NOT NULL DEFAULT 'v1',
    dimensions smallint NOT NULL DEFAULT 512 CHECK (dimensions = 512),
    source_content_hash char(64) NOT NULL
        CHECK (source_content_hash ~ '^[0-9a-f]{64}$'),
    embedding vector(512) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (memory_id, embedding_model, embedding_version),
    FOREIGN KEY (workspace_id, memory_id)
        REFERENCES continuum.memories(workspace_id, id) ON DELETE CASCADE
);

CREATE INDEX memory_embeddings_workspace_idx
ON continuum.memory_embeddings (workspace_id, memory_id);

CREATE INDEX memory_embeddings_hnsw_cosine_idx
ON continuum.memory_embeddings
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- 15. memory_edges: short-path graph used by hybrid retrieval.
CREATE TABLE continuum.memory_edges (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    from_memory_id uuid NOT NULL,
    to_memory_id uuid NOT NULL,
    relation text NOT NULL,
    weight numeric(7,6) NOT NULL DEFAULT 1 CHECK (weight BETWEEN 0 AND 1),
    provenance continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    valid_from timestamptz,
    valid_until timestamptz,
    invalidated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, from_memory_id, to_memory_id, relation),
    FOREIGN KEY (workspace_id, from_memory_id)
        REFERENCES continuum.memories(workspace_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, to_memory_id)
        REFERENCES continuum.memories(workspace_id, id) ON DELETE CASCADE,
    CHECK (from_memory_id <> to_memory_id),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until > valid_from)
);

CREATE INDEX memory_edges_outbound_idx
ON continuum.memory_edges (workspace_id, from_memory_id, relation)
WHERE invalidated_at IS NULL;

CREATE INDEX memory_edges_inbound_idx
ON continuum.memory_edges (workspace_id, to_memory_id, relation)
WHERE invalidated_at IS NULL;

-- 16. failures: persistent failure learning and deduplicated recurrence.
CREATE TABLE continuum.failures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    run_id uuid,
    agent_version_id uuid,
    tool_execution_id uuid,
    failure_type text NOT NULL,
    error_code text,
    summary text NOT NULL CHECK (btrim(summary) <> ''),
    detail_artifact_id uuid,
    retryable boolean NOT NULL DEFAULT false,
    fingerprint char(64) NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    root_cause continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    resolution continuum.jsonb_256k,
    occurrence_count integer NOT NULL DEFAULT 1 CHECK (occurrence_count >= 1),
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'mitigated', 'resolved', 'accepted')),
    learned_memory_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, fingerprint),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, agent_version_id)
        REFERENCES continuum.agent_versions(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, detail_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, learned_memory_id)
        REFERENCES continuum.memories(workspace_id, id) ON DELETE SET NULL,
    CHECK (last_seen_at >= first_seen_at)
);

CREATE INDEX failures_workspace_status_last_seen_idx
ON continuum.failures (workspace_id, status, last_seen_at DESC);

-- 17. tools: stable controlled-tool identity.
CREATE TABLE continuum.tools (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    name text NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9._-]{2,127}$'),
    purpose text NOT NULL CHECK (char_length(purpose) >= 8),
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'quarantined', 'shadow', 'canary', 'active', 'paused', 'retired')),
    current_version_id uuid,
    created_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, name)
);

-- 18. tool_versions: immutable manifest, digest, permissions, and approval policy.
CREATE TABLE continuum.tool_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    tool_id uuid NOT NULL,
    version text NOT NULL CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
    manifest_sha256 char(64) NOT NULL CHECK (manifest_sha256 ~ '^[0-9a-f]{64}$'),
    package_artifact_id uuid,
    risk_level smallint NOT NULL CHECK (risk_level BETWEEN 0 AND 4),
    side_effect text NOT NULL
        CHECK (side_effect IN ('none', 'internal_write', 'reversible_external_write', 'irreversible_external_write')),
    reversible boolean NOT NULL DEFAULT false,
    idempotency continuum.jsonb_256k NOT NULL,
    permissions continuum.jsonb_256k NOT NULL,
    resources continuum.jsonb_256k NOT NULL,
    approval continuum.jsonb_256k NOT NULL,
    input_schema continuum.jsonb_256k NOT NULL,
    output_schema continuum.jsonb_256k NOT NULL,
    provenance continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'quarantined'
        CHECK (status IN ('quarantined', 'tested', 'shadow', 'canary', 'active', 'rejected', 'retired')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, tool_id, version),
    UNIQUE (workspace_id, tool_id, manifest_sha256),
    FOREIGN KEY (workspace_id, tool_id)
        REFERENCES continuum.tools(workspace_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, package_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE RESTRICT,
    CHECK (risk_level < 3 OR approval @> '{"required": true}'::jsonb)
);

-- v1.2 permits a human-controlled level-4 promotion but forbids automatic
-- promotion. That actor/workflow rule is intentionally not weakened into an
-- inaccurate table-level ban on all active level-4 tools.

ALTER TABLE continuum.tools
    ADD CONSTRAINT tools_current_version_fk
    FOREIGN KEY (workspace_id, current_version_id)
    REFERENCES continuum.tool_versions(workspace_id, id) ON DELETE SET NULL;

-- 19. tool_executions: idempotent, approved, auditable side-effect execution.
CREATE TABLE continuum.tool_executions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    run_id uuid,
    tool_version_id uuid NOT NULL,
    requested_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    idempotency_key text,
    status text NOT NULL DEFAULT 'requested'
        CHECK (status IN ('requested', 'awaiting_approval', 'approved', 'running', 'succeeded', 'failed', 'denied', 'cancelled')),
    approval_status text NOT NULL DEFAULT 'not_required'
        CHECK (approval_status IN ('not_required', 'pending', 'approved', 'rejected', 'expired')),
    approved_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    approved_at timestamptz,
    input continuum.jsonb_256k NOT NULL,
    output continuum.jsonb_256k,
    input_artifact_id uuid,
    output_artifact_id uuid,
    side_effect_receipt continuum.jsonb_256k,
    error continuum.jsonb_256k,
    cost_usd numeric(18,9) NOT NULL DEFAULT 0 CHECK (cost_usd >= 0),
    trace_id char(32) CHECK (trace_id IS NULL OR trace_id ~ '^[0-9a-f]{32}$'),
    requested_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, tool_version_id)
        REFERENCES continuum.tool_versions(workspace_id, id) ON DELETE RESTRICT,
    FOREIGN KEY (workspace_id, input_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE RESTRICT,
    FOREIGN KEY (workspace_id, output_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE RESTRICT,
    CHECK ((approval_status = 'approved') = (approved_at IS NOT NULL)),
    CHECK (completed_at IS NULL OR started_at IS NOT NULL),
    CHECK (completed_at IS NULL OR completed_at >= started_at)
);

CREATE UNIQUE INDEX tool_executions_idempotency_uq
ON continuum.tool_executions (workspace_id, tool_version_id, idempotency_key)
WHERE idempotency_key IS NOT NULL;

CREATE INDEX tool_executions_run_status_idx
ON continuum.tool_executions (workspace_id, run_id, status, requested_at DESC);

ALTER TABLE continuum.failures
    ADD CONSTRAINT failures_tool_execution_fk
    FOREIGN KEY (workspace_id, tool_execution_id)
    REFERENCES continuum.tool_executions(workspace_id, id) ON DELETE SET NULL;

-- 20. evaluations: versioned evaluation suite/dataset definition.
CREATE TABLE continuum.evaluations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    name text NOT NULL,
    version text NOT NULL,
    purpose text NOT NULL,
    suite_type text NOT NULL
        CHECK (suite_type IN ('golden', 'retrieval', 'adversarial', 'security', 'temporal', 'chaos', 'economics', 'custom')),
    dataset_artifact_id uuid,
    configuration continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'active', 'holdout', 'retired')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, name, version),
    FOREIGN KEY (workspace_id, dataset_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE RESTRICT
);

-- 21. evaluation_results: immutable outcome for a subject/sample.
CREATE TABLE continuum.evaluation_results (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    evaluation_id uuid NOT NULL,
    run_id uuid,
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    sample_id text NOT NULL,
    score numeric(12,9),
    passed boolean,
    metrics continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    output_artifact_id uuid,
    evaluator_version text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    UNIQUE (workspace_id, evaluation_id, subject_type, subject_id, sample_id, evaluator_version),
    FOREIGN KEY (workspace_id, evaluation_id)
        REFERENCES continuum.evaluations(workspace_id, id) ON DELETE RESTRICT,
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, output_artifact_id)
        REFERENCES continuum.artifacts(workspace_id, id) ON DELETE RESTRICT
);

CREATE INDEX evaluation_results_subject_idx
ON continuum.evaluation_results (workspace_id, subject_type, subject_id, created_at DESC);

-- 22. mutations: fully traced candidate change and promotion lifecycle.
CREATE TABLE continuum.mutations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    parent_mutation_id uuid,
    mutation_class text NOT NULL
        CHECK (mutation_class IN ('agent', 'prompt', 'tool', 'workflow', 'retrieval', 'model_route', 'policy', 'context_budget')),
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    proposal continuum.jsonb_256k NOT NULL,
    rationale text NOT NULL,
    risk_level smallint NOT NULL CHECK (risk_level BETWEEN 0 AND 4),
    status text NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed', 'quarantined', 'evaluating', 'shadow', 'canary', 'approved', 'promoted', 'rejected', 'rolled_back')),
    git_branch text,
    git_commit_sha char(40) CHECK (git_commit_sha IS NULL OR git_commit_sha ~ '^[0-9a-f]{40}$'),
    approved_by_user_id uuid REFERENCES continuum.users(id) ON DELETE SET NULL,
    approved_at timestamptz,
    promoted_at timestamptz,
    rolled_back_at timestamptz,
    rollback_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, id),
    FOREIGN KEY (workspace_id, parent_mutation_id)
        REFERENCES continuum.mutations(workspace_id, id) ON DELETE SET NULL,
    CHECK (approved_at IS NULL OR approved_by_user_id IS NOT NULL),
    CHECK ((status = 'promoted') = (promoted_at IS NOT NULL)),
    CHECK ((status = 'rolled_back') = (rolled_back_at IS NOT NULL)),
    CHECK (rolled_back_at IS NULL OR rollback_reason IS NOT NULL)
);

CREATE INDEX mutations_workspace_status_idx
ON continuum.mutations (workspace_id, status, created_at DESC);

-- 23. mutation_evaluations: baseline/candidate statistics and decision lineage.
CREATE TABLE continuum.mutation_evaluations (
    workspace_id uuid NOT NULL,
    mutation_id uuid NOT NULL,
    evaluation_result_id uuid NOT NULL,
    baseline_metrics continuum.jsonb_256k NOT NULL,
    candidate_metrics continuum.jsonb_256k NOT NULL,
    quality_delta numeric(12,9),
    cost_delta numeric(12,9),
    failure_rate_delta numeric(12,9),
    confidence_interval_lower numeric(12,9),
    confidence_interval_upper numeric(12,9),
    sample_size integer NOT NULL CHECK (sample_size > 0),
    decision text NOT NULL CHECK (decision IN ('continue', 'promote', 'reject', 'rollback')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, mutation_id, evaluation_result_id),
    FOREIGN KEY (workspace_id, mutation_id)
        REFERENCES continuum.mutations(workspace_id, id) ON DELETE CASCADE,
    FOREIGN KEY (workspace_id, evaluation_result_id)
        REFERENCES continuum.evaluation_results(workspace_id, id) ON DELETE RESTRICT,
    CHECK (
        confidence_interval_upper IS NULL
        OR confidence_interval_lower IS NULL
        OR confidence_interval_upper >= confidence_interval_lower
    )
);

-- 24. events: exact v1.2 event envelope, append-only and hash chained.
CREATE TABLE continuum.events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL
        REFERENCES continuum.workspaces(id) ON DELETE RESTRICT,
    run_id uuid,
    event_type text NOT NULL,
    schema_version integer NOT NULL CHECK (schema_version > 0),
    aggregate_type text NOT NULL,
    aggregate_id uuid NOT NULL,
    causation_event_id uuid,
    correlation_id uuid NOT NULL,
    actor_type text NOT NULL,
    actor_id uuid,
    trace_id char(32) CHECK (trace_id IS NULL OR trace_id ~ '^[0-9a-f]{32}$'),
    payload continuum.jsonb_256k NOT NULL,
    previous_hash char(64) CHECK (previous_hash IS NULL OR previous_hash ~ '^[0-9a-f]{64}$'),
    event_hash char(64) NOT NULL CHECK (event_hash ~ '^[0-9a-f]{64}$'),
    occurred_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, event_id),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, causation_event_id)
        REFERENCES continuum.events(workspace_id, event_id) ON DELETE RESTRICT,
    CHECK (ingested_at >= occurred_at - interval '24 hours')
);

CREATE INDEX events_workspace_ingested_idx
ON continuum.events (workspace_id, ingested_at, event_id);

CREATE INDEX events_aggregate_idx
ON continuum.events (workspace_id, aggregate_type, aggregate_id, occurred_at, event_id);

CREATE INDEX events_run_idx
ON continuum.events (workspace_id, run_id, occurred_at, event_id)
WHERE run_id IS NOT NULL;

CREATE OR REPLACE FUNCTION continuum.prepare_event_hash()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, continuum
SET row_security = off
AS $$
DECLARE
    expected_previous char(64);
    hash_document jsonb;
    calculated_hash char(64);
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.workspace_id::text, 0));

    SELECT e.event_hash
      INTO expected_previous
      FROM continuum.events e
     WHERE e.workspace_id = NEW.workspace_id
     ORDER BY e.ingested_at DESC, e.event_id DESC
     LIMIT 1;

    IF NEW.previous_hash IS NOT NULL
       AND NEW.previous_hash IS DISTINCT FROM expected_previous THEN
        RAISE EXCEPTION 'event previous_hash does not match workspace chain head'
            USING ERRCODE = '23514';
    END IF;

    NEW.previous_hash := expected_previous;

    hash_document := jsonb_build_object(
        'event_id', NEW.event_id,
        'workspace_id', NEW.workspace_id,
        'run_id', NEW.run_id,
        'event_type', NEW.event_type,
        'schema_version', NEW.schema_version,
        'aggregate_type', NEW.aggregate_type,
        'aggregate_id', NEW.aggregate_id,
        'causation_event_id', NEW.causation_event_id,
        'correlation_id', NEW.correlation_id,
        'actor_type', NEW.actor_type,
        'actor_id', NEW.actor_id,
        'trace_id', NEW.trace_id,
        'payload', NEW.payload,
        'previous_hash', NEW.previous_hash,
        'occurred_at', NEW.occurred_at
    );

    calculated_hash := encode(digest(hash_document::text, 'sha256'), 'hex');

    IF NEW.event_hash IS NOT NULL AND NEW.event_hash <> calculated_hash THEN
        RAISE EXCEPTION 'event_hash does not match canonical event document'
            USING ERRCODE = '23514';
    END IF;

    NEW.event_hash := calculated_hash;
    RETURN NEW;
END;
$$;

CREATE TRIGGER events_prepare_hash
BEFORE INSERT ON continuum.events
FOR EACH ROW EXECUTE FUNCTION continuum.prepare_event_hash();

CREATE TRIGGER events_reject_update_delete
BEFORE UPDATE OR DELETE ON continuum.events
FOR EACH ROW EXECUTE FUNCTION continuum.reject_ledger_mutation();

CREATE TRIGGER events_reject_truncate
BEFORE TRUNCATE ON continuum.events
FOR EACH STATEMENT EXECUTE FUNCTION continuum.reject_ledger_mutation();

-- 25. cost_events: append-only direct COGS ledger.
CREATE TABLE continuum.cost_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid NOT NULL,
    run_id uuid,
    source_event_id uuid,
    category text NOT NULL
        CHECK (category IN ('model', 'tool_api', 'temporal', 'eks', 'sandbox', 'database', 's3', 'network', 'observability', 'other')),
    provider text NOT NULL,
    sku text NOT NULL,
    quantity numeric(24,9) NOT NULL CHECK (quantity >= 0),
    unit text NOT NULL,
    unit_price_usd numeric(24,12) NOT NULL CHECK (unit_price_usd >= 0),
    cost_usd numeric(24,12) GENERATED ALWAYS AS (quantity * unit_price_usd) STORED,
    pricing_catalog_version text NOT NULL,
    provider_record_id text,
    occurred_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT now(),
    metadata continuum.jsonb_256k NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (workspace_id, id),
    FOREIGN KEY (workspace_id, run_id)
        REFERENCES continuum.runs(workspace_id, id) ON DELETE SET NULL,
    FOREIGN KEY (workspace_id, source_event_id)
        REFERENCES continuum.events(workspace_id, event_id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX cost_events_provider_record_uq
ON continuum.cost_events (workspace_id, provider, provider_record_id)
WHERE provider_record_id IS NOT NULL;

CREATE INDEX cost_events_run_occurred_idx
ON continuum.cost_events (workspace_id, run_id, occurred_at DESC);

CREATE INDEX cost_events_workspace_category_idx
ON continuum.cost_events (workspace_id, category, occurred_at DESC);

CREATE TRIGGER cost_events_reject_update_delete
BEFORE UPDATE OR DELETE ON continuum.cost_events
FOR EACH ROW EXECUTE FUNCTION continuum.reject_ledger_mutation();

CREATE TRIGGER cost_events_reject_truncate
BEFORE TRUNCATE ON continuum.cost_events
FOR EACH STATEMENT EXECUTE FUNCTION continuum.reject_ledger_mutation();

-- Mutable-record timestamp maintenance.
CREATE TRIGGER users_set_updated_at BEFORE UPDATE ON continuum.users
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER workspaces_set_updated_at BEFORE UPDATE ON continuum.workspaces
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER workspace_members_set_updated_at BEFORE UPDATE ON continuum.workspace_members
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER runs_set_updated_at BEFORE UPDATE ON continuum.runs
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER agents_set_updated_at BEFORE UPDATE ON continuum.agents
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER models_set_updated_at BEFORE UPDATE ON continuum.models
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER claims_set_updated_at BEFORE UPDATE ON continuum.claims
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER memories_set_updated_at BEFORE UPDATE ON continuum.memories
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER failures_set_updated_at BEFORE UPDATE ON continuum.failures
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER tools_set_updated_at BEFORE UPDATE ON continuum.tools
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER evaluations_set_updated_at BEFORE UPDATE ON continuum.evaluations
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();
CREATE TRIGGER mutations_set_updated_at BEFORE UPDATE ON continuum.mutations
FOR EACH ROW EXECUTE FUNCTION continuum.set_updated_at();

-- Workspace-scoped row-level security.
ALTER TABLE continuum.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.workspaces FORCE ROW LEVEL SECURITY;
CREATE POLICY workspaces_workspace_isolation ON continuum.workspaces
USING (id = continuum.current_workspace_id())
WITH CHECK (id = continuum.current_workspace_id());

ALTER TABLE continuum.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.users FORCE ROW LEVEL SECURITY;
CREATE POLICY users_visible_through_membership ON continuum.users
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM continuum.workspace_members wm
        WHERE wm.workspace_id = continuum.current_workspace_id()
          AND wm.user_id = users.id
          AND wm.status = 'active'
    )
);

ALTER TABLE continuum.workspace_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.workspace_members FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_members_workspace_isolation ON continuum.workspace_members
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.runs FORCE ROW LEVEL SECURITY;
CREATE POLICY runs_workspace_isolation ON continuum.runs
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.artifacts FORCE ROW LEVEL SECURITY;
CREATE POLICY artifacts_workspace_isolation ON continuum.artifacts
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.agents FORCE ROW LEVEL SECURITY;
CREATE POLICY agents_workspace_isolation ON continuum.agents
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.agent_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.agent_versions FORCE ROW LEVEL SECURITY;
CREATE POLICY agent_versions_workspace_isolation ON continuum.agent_versions
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.models ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.models FORCE ROW LEVEL SECURITY;
CREATE POLICY models_workspace_isolation ON continuum.models
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.model_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.model_metrics FORCE ROW LEVEL SECURITY;
CREATE POLICY model_metrics_workspace_isolation ON continuum.model_metrics
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.evidence FORCE ROW LEVEL SECURITY;
CREATE POLICY evidence_workspace_isolation ON continuum.evidence
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.claims FORCE ROW LEVEL SECURITY;
CREATE POLICY claims_workspace_isolation ON continuum.claims
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.claim_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.claim_evidence FORCE ROW LEVEL SECURITY;
CREATE POLICY claim_evidence_workspace_isolation ON continuum.claim_evidence
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.memories FORCE ROW LEVEL SECURITY;
CREATE POLICY memories_workspace_isolation ON continuum.memories
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.memory_embeddings ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.memory_embeddings FORCE ROW LEVEL SECURITY;
CREATE POLICY memory_embeddings_workspace_isolation ON continuum.memory_embeddings
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.memory_edges ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.memory_edges FORCE ROW LEVEL SECURITY;
CREATE POLICY memory_edges_workspace_isolation ON continuum.memory_edges
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.failures ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.failures FORCE ROW LEVEL SECURITY;
CREATE POLICY failures_workspace_isolation ON continuum.failures
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.tools ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.tools FORCE ROW LEVEL SECURITY;
CREATE POLICY tools_workspace_isolation ON continuum.tools
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.tool_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.tool_versions FORCE ROW LEVEL SECURITY;
CREATE POLICY tool_versions_workspace_isolation ON continuum.tool_versions
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.tool_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.tool_executions FORCE ROW LEVEL SECURITY;
CREATE POLICY tool_executions_workspace_isolation ON continuum.tool_executions
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.evaluations FORCE ROW LEVEL SECURITY;
CREATE POLICY evaluations_workspace_isolation ON continuum.evaluations
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.evaluation_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.evaluation_results FORCE ROW LEVEL SECURITY;
CREATE POLICY evaluation_results_workspace_isolation ON continuum.evaluation_results
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.mutations ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.mutations FORCE ROW LEVEL SECURITY;
CREATE POLICY mutations_workspace_isolation ON continuum.mutations
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.mutation_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.mutation_evaluations FORCE ROW LEVEL SECURITY;
CREATE POLICY mutation_evaluations_workspace_isolation ON continuum.mutation_evaluations
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.events FORCE ROW LEVEL SECURITY;
CREATE POLICY events_workspace_isolation ON continuum.events
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

ALTER TABLE continuum.cost_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.cost_events FORCE ROW LEVEL SECURITY;
CREATE POLICY cost_events_workspace_isolation ON continuum.cost_events
USING (workspace_id = continuum.current_workspace_id())
WITH CHECK (workspace_id = continuum.current_workspace_id());

-- The deployment migration must explicitly grant only the required privileges
-- to environment-specific roles. No application role may own these tables.
REVOKE ALL ON SCHEMA continuum FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA continuum FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA continuum FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA continuum FROM PUBLIC;

COMMIT;
