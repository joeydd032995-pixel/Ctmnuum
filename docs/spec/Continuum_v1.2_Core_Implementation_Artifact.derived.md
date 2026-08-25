# Continuum v1.2 — Core Implementation Artifact (DERIVED)

> **STATUS: DERIVED RECONSTRUCTION. THIS IS NOT RECOVERED SOURCE TEXT.**
>
> The original machine-readable artifact referenced by the v1.2 report at
> `sandbox:/mnt/data/Continuum_v1.2_Implementation_Specification.md` was
> generated during the specification session and never persisted. It is not
> present in any document available to this project and is considered
> unrecoverable.
>
> This document reconstructs that artifact's stated contents — core PostgreSQL
> DDL, event schema, dependency baseline, and Temporal definitions — from the
> surviving normative material. **No part of it may be cited as recovered v1.2
> specification text.** Per `CONT-LOCAL-GOV-001`, every element carries a
> provenance tag, and every element not directly supported by source material is
> marked as a decision requiring ADR approval.

## 0. Provenance model

Every declaration below carries exactly one tag.

| Tag | Meaning | May be cited as v1.2? |
|---|---|---|
| `[V12]` | Stated directly in the v1.2 report/PDF. Reproduced, not inferred. | Yes |
| `[V11]` | Carried from the v1.0/v1.1 reference architecture, which v1.2 names as its predecessor. | No — predecessor text |
| `[DERIVED]` | Inferred from an explicit v1.2 invariant. The invariant is cited; the encoding is not source. | No |
| `[DECISION]` | No source support. A choice made to produce a working schema. **Requires ADR approval.** | No |

### Source documents

| Document | SHA-256 (first 16) | Role |
|---|---|---|
| `deepresearchreport.md` | `af4bef0e0409d59a` | v1.2 normative text |
| `Continuum_v1.2_...PDF` | `5a8311c064e42ba3` | same content, rendered |
| `Continuum_v1.1.pdf` | `dc222b7d9b352b9a` | predecessor architecture |
| `Continuum1.0.pdf` | `52e37fd4e5eb72a8` | predecessor; schema content identical to v1.1 |

### What the surviving corpus actually contained

| Artifact content | Found in source |
|---|---|
| Core PostgreSQL DDL | **1 of 25 tables** (`memory_embeddings`, complete) `[V12]` |
| | 2 predecessor tables (`knowledge_edges`, `run_events`) `[V11]` |
| Event schema | 17 field **names**, no types `[V12]` |
| Dependency baseline | 6 Terraform providers pinned exactly `[V12]`; no language-level pins |
| Temporal definitions | Complete **except Activity timeouts**, which the report explicitly defers to the missing artifact |

---

## 1. Schema, extensions and roles

Already implemented on `main` and approved under **ADR-0001**. Reproduced here
for completeness; this section is not new.

```sql
CREATE SCHEMA IF NOT EXISTS continuum;              -- [V12] schema-qualified in source DDL
CREATE EXTENSION IF NOT EXISTS vector;              -- [V12] pgvector required

CREATE ROLE continuum_app         NOLOGIN NOBYPASSRLS;  -- [V12] invariant, [DECISION] names
CREATE ROLE continuum_migration   NOLOGIN NOBYPASSRLS;
CREATE ROLE continuum_maintenance NOLOGIN NOBYPASSRLS;

-- [V12] transaction-scoped tenant context, fails closed when unset
CREATE OR REPLACE FUNCTION continuum.current_workspace_id()
RETURNS uuid LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT NULLIF(current_setting('app.workspace_id', true), '')::uuid;
$$;
```

PostgreSQL **18** is the baseline. `[V12]`

---

## 2. Enumerated types

```sql
-- [V11] ClaimStatus, reproduced from the v1.1 typed model
CREATE TYPE continuum.claim_status AS ENUM (
    'supported', 'contested', 'inferred', 'unverified', 'falsified'
);

-- [V11] EvidenceType, reproduced from the v1.1 typed model
CREATE TYPE continuum.evidence_type AS ENUM (
    'user', 'first_party', 'verified_connector',
    'public_source', 'experiment', 'tool_result'
);

-- [V12] memory lifecycle: temporary -> candidate -> validated -> durable,
--       with stateful invalidation rather than deletion
CREATE TYPE continuum.memory_status AS ENUM (
    'temporary', 'candidate', 'validated', 'durable', 'invalidated'
);

-- [DECISION] memory classes named in v1.2 context-budget allocation
--            (semantic/episodic, procedural) plus failure memory
CREATE TYPE continuum.memory_type AS ENUM (
    'semantic', 'episodic', 'procedural', 'failure'
);

-- [V12] artifact classification enum, verbatim from the artifact manifest
CREATE TYPE continuum.artifact_classification AS ENUM (
    'public', 'internal', 'confidential', 'restricted'
);

-- [V12] artifact retention classes, verbatim from the artifact manifest
CREATE TYPE continuum.retention_class AS ENUM (
    'ephemeral', 'standard', 'durable', 'immutable', 'legal_hold'
);

-- [V12] tool side-effect enum, verbatim from the tool manifest
CREATE TYPE continuum.side_effect AS ENUM (
    'none', 'internal_write', 'reversible_external_write', 'irreversible_external_write'
);

-- [V12] idempotency strategy enum, verbatim from the tool manifest
CREATE TYPE continuum.idempotency_strategy AS ENUM (
    'none', 'caller_key', 'provider_key', 'database_dedup'
);

-- [V12] mutation classes, verbatim from the Evolution section
CREATE TYPE continuum.mutation_class AS ENUM (
    'agent', 'prompt', 'tool', 'workflow',
    'retrieval', 'model_route', 'policy', 'context_budget'
);

-- [DERIVED] promotion stages, from the v1.2 pipeline
--           quarantine -> tests -> benchmark -> shadow -> canary -> approval -> promoted
CREATE TYPE continuum.promotion_stage AS ENUM (
    'proposed', 'quarantined', 'benchmarked', 'shadow',
    'canary', 'approved', 'promoted', 'rejected', 'rolled_back'
);

-- [DECISION] run lifecycle; v1.2 names terminal success as a gate metric
--            but does not enumerate the state machine
CREATE TYPE continuum.run_status AS ENUM (
    'accepted', 'running', 'succeeded', 'failed', 'cancelled'
);
```

---

## 3. Core PostgreSQL DDL

v1.2 names exactly these 25 tables. `[V12]`

Universal column rule, applied to every high-volume table: `workspace_id`,
`created_at`, and `trace_id` where applicable. `[V11]`

### 3.1 Tenancy and identity

```sql
CREATE TABLE continuum.users (
    id            uuid PRIMARY KEY,                      -- [DERIVED]
    email         citext NOT NULL UNIQUE,                -- [DECISION]
    display_name  text,                                  -- [DECISION]
    status        text NOT NULL DEFAULT 'active',        -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now(),    -- [V11]
    updated_at    timestamptz NOT NULL DEFAULT now()     -- [DECISION]
);

CREATE TABLE continuum.workspaces (
    id            uuid PRIMARY KEY,                      -- [V12] FK target in source DDL
    name          text NOT NULL,                         -- [DECISION]
    plan_tier     text NOT NULL DEFAULT 'free'           -- [V12] fairness weights are per plan tier
        CHECK (plan_tier IN ('free','pro','team','enterprise','internal')),
    status        text NOT NULL DEFAULT 'active',        -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now(),    -- [V11]
    updated_at    timestamptz NOT NULL DEFAULT now()     -- [DECISION]
);

CREATE TABLE continuum.workspace_members (
    workspace_id  uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    user_id       uuid NOT NULL REFERENCES continuum.users(id) ON DELETE CASCADE,
    role          text NOT NULL DEFAULT 'member'         -- [DECISION]
        CHECK (role IN ('owner','admin','member','viewer')),
    created_at    timestamptz NOT NULL DEFAULT now(),    -- [V11]
    PRIMARY KEY (workspace_id, user_id)                  -- [DERIVED]
);
```

> `plan_tier` values are `[DECISION]`; v1.2 states fairness weights for
> internal/enterprise 2.0, team/builder 1.5, pro/personal 1.0, free 0.5 but does
> not fix the stored vocabulary.

### 3.2 Runs

```sql
CREATE TABLE continuum.runs (
    id                uuid PRIMARY KEY,                              -- [V12] named table
    workspace_id      uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,  -- [V11]
    created_by        uuid REFERENCES continuum.users(id),           -- [DECISION]
    status            continuum.run_status NOT NULL DEFAULT 'accepted',  -- [DECISION]
    objective         text NOT NULL,                                 -- [DERIVED] goal is a ContextBundle field
    depth             text NOT NULL DEFAULT 'standard'               -- [V12] Watcher coverage on "Deep/Critical"
        CHECK (depth IN ('quick','standard','deep','critical')),
    token_budget      integer CHECK (token_budget > 0 AND token_budget <= 200000),  -- [V12] CompileContextInput bound
    budget_usd        numeric(12,6),                                 -- [V12] ModelRequest.budget_usd
    deadline_at       timestamptz,                                   -- [V12] ActivityContext.deadline_at
    workflow_id       text,                                          -- [DERIVED] Temporal ownership boundary
    workflow_run_id   text,                                          -- [DERIVED]
    trace_id          char(32) CHECK (trace_id ~ '^[0-9a-f]{32}$'),  -- [V12] ActivityContext pattern
    started_at        timestamptz,                                   -- [DECISION]
    completed_at      timestamptz,                                   -- [DECISION]
    created_at        timestamptz NOT NULL DEFAULT now()             -- [V11]
);

CREATE INDEX runs_workspace_created_idx
    ON continuum.runs (workspace_id, created_at DESC);               -- [DERIVED]
```

### 3.3 Agents

```sql
CREATE TABLE continuum.agents (
    id            uuid PRIMARY KEY,                                  -- [V12] named table
    workspace_id  uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,  -- [DERIVED] null = built-in
    name          text NOT NULL,                                     -- [DECISION]
    role          text NOT NULL,                                     -- [V12] planner/researcher/analyst/skeptic/synthesizer
    status        text NOT NULL DEFAULT 'active',                    -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now(),                -- [V11]
    UNIQUE (workspace_id, name)                                      -- [DECISION]
);

-- [V12] "Every important object is versioned": prompts, agent definitions,
--       models, tools, workflows, memory, policies, evaluators
CREATE TABLE continuum.agent_versions (
    id                uuid PRIMARY KEY,                              -- [V12] referenced as agent_version_id
    agent_id          uuid NOT NULL REFERENCES continuum.agents(id) ON DELETE CASCADE,
    workspace_id      uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    version           integer NOT NULL,                              -- [DERIVED]
    prompt_hash       char(64) NOT NULL,                             -- [DERIVED] prompts are versioned objects
    prompt_artifact_id uuid,                                         -- [V12] >256 KiB offloads to S3
    config            jsonb NOT NULL DEFAULT '{}'::jsonb,            -- [DECISION]
    output_schema_id  text,                                          -- [V12] ExecuteAgentInput field
    status            continuum.promotion_stage NOT NULL DEFAULT 'promoted',  -- [DERIVED]
    created_at        timestamptz NOT NULL DEFAULT now(),            -- [V11]
    UNIQUE (agent_id, version)                                       -- [DERIVED]
);
```

### 3.4 Models

```sql
CREATE TABLE continuum.models (
    id            uuid PRIMARY KEY,                                  -- [V12] named table
    provider      text NOT NULL,                                     -- [V12] ModelResponse.provider
    model_id      text NOT NULL,                                     -- [V12] ModelResponse.model_id
    snapshot_id   text,                                              -- [V12] ModelResponse.snapshot_id
    profile       text                                               -- [V12] economical / high_reasoning / embedding
        CHECK (profile IN ('economical','high_reasoning','embedding')),
    status        text NOT NULL DEFAULT 'active'                     -- [V12] "model status" is a hard router filter
        CHECK (status IN ('active','shadow','deprecated','disabled')),
    capabilities  jsonb NOT NULL DEFAULT '{}'::jsonb,                -- [V12] ModelProvider.capabilities()
    created_at    timestamptz NOT NULL DEFAULT now(),                -- [V11]
    UNIQUE (provider, model_id, snapshot_id)                         -- [DERIVED]
);

CREATE TABLE continuum.model_metrics (
    id                  uuid PRIMARY KEY,                            -- [V12] named table
    model_id            uuid NOT NULL REFERENCES continuum.models(id) ON DELETE CASCADE,
    workspace_id        uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    task_family         text NOT NULL,                               -- [V12] ModelRequest.task_family
    window_start        timestamptz NOT NULL,                        -- [DECISION]
    window_end          timestamptz NOT NULL,                        -- [DECISION]
    sample_count        integer NOT NULL CHECK (sample_count >= 0),  -- [DECISION]
    success_rate        double precision CHECK (success_rate BETWEEN 0 AND 1),   -- [V12] Q in router utility
    calibration_error   double precision CHECK (calibration_error >= 0),         -- [V12] ECE <= 0.08 gate
    brier_score         double precision CHECK (brier_score >= 0),               -- [V12] Brier gate
    p95_latency_ms      integer,                                     -- [V12] L in router utility
    availability        double precision CHECK (availability BETWEEN 0 AND 1),   -- [V12] A in router utility
    mean_cost_usd       numeric(12,6),                               -- [V12] K in router utility
    created_at          timestamptz NOT NULL DEFAULT now()           -- [V11]
);
```

### 3.5 Claims and evidence

Reproduced from the v1.1 typed `Claim` and `Evidence` models. `[V11]`

```sql
CREATE TABLE continuum.evidence (
    id            uuid PRIMARY KEY,                                  -- [V11] Evidence.id
    workspace_id  uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id        uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    type          continuum.evidence_type NOT NULL,                  -- [V11] Evidence.type
    uri           text,                                              -- [V11] Evidence.uri
    content_hash  char(64) NOT NULL,                                 -- [V11] Evidence.content_hash
    observed_at   timestamptz NOT NULL,                              -- [V11] Evidence.observed_at
    valid_from    timestamptz,                                       -- [V11] Evidence.valid_from
    valid_until   timestamptz,                                       -- [V11] Evidence.valid_until
    trust_score   double precision NOT NULL                          -- [V11] Evidence.trust_score, ge=0 le=1
        CHECK (trust_score BETWEEN 0 AND 1),
    payload       jsonb NOT NULL DEFAULT '{}'::jsonb,                -- [V11] Evidence.payload
    payload_artifact_id uuid,                                        -- [V12] >256 KiB offloads to S3
    trace_id      char(32),                                          -- [V11] universal column rule
    created_at    timestamptz NOT NULL DEFAULT now()                 -- [V11]
);

CREATE TABLE continuum.claims (
    id                        uuid PRIMARY KEY,                      -- [V11] Claim.id
    workspace_id              uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id                    uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    statement                 text NOT NULL,                         -- [V11] Claim.statement
    status                    continuum.claim_status NOT NULL,       -- [V11] Claim.status
    confidence                double precision NOT NULL              -- [V11] Claim.confidence, ge=0 le=1
        CHECK (confidence BETWEEN 0 AND 1),
    assumptions               text[] NOT NULL DEFAULT '{}',          -- [V11] Claim.assumptions
    falsification_conditions  text[] NOT NULL DEFAULT '{}',          -- [V11] Claim.falsification_conditions
    created_by_agent_version  uuid REFERENCES continuum.agent_versions(id),  -- [V11]
    superseded_by             uuid REFERENCES continuum.claims(id),  -- [DERIVED] belief change stays visible
    trace_id                  char(32),                              -- [V11]
    created_at                timestamptz NOT NULL DEFAULT now()     -- [V11] Claim.created_at
);

-- [V12] named table. v1.1 modelled the relation as two id arrays on Claim;
-- normalising to a join table preserves the same information and makes the
-- "why do you believe X" traversal indexable.  [DERIVED] encoding.
CREATE TABLE continuum.claim_evidence (
    claim_id      uuid NOT NULL REFERENCES continuum.claims(id) ON DELETE CASCADE,
    evidence_id   uuid NOT NULL REFERENCES continuum.evidence(id) ON DELETE CASCADE,
    workspace_id  uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    stance        text NOT NULL                                      -- [V11] supporting vs opposing evidence ids
        CHECK (stance IN ('supports','opposes')),
    weight        double precision CHECK (weight BETWEEN 0 AND 1),   -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now(),                -- [V11]
    PRIMARY KEY (claim_id, evidence_id, stance)                      -- [DERIVED]
);

CREATE INDEX claim_evidence_evidence_idx
    ON continuum.claim_evidence (evidence_id);                       -- [DERIVED] reverse traversal
```

### 3.6 Memory

```sql
CREATE TABLE continuum.memories (
    id             uuid PRIMARY KEY,                                 -- [V12] FK target in source DDL
    workspace_id   uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,  -- [V12] query predicate
    memory_type    continuum.memory_type NOT NULL,                   -- [V12] selected in the source query
    content        text NOT NULL,                                    -- [V12] selected in the source query
    content_hash   char(64) NOT NULL,                                -- [V12] content-hash mismatch = 0 is a gate
    content_artifact_id uuid,                                        -- [V12] >256 KiB offloads to S3
    status         continuum.memory_status NOT NULL DEFAULT 'temporary',  -- [V12] query filters on status
    invalidated_at timestamptz,                                      -- [V12] query predicate
    superseded_by  uuid REFERENCES continuum.memories(id),           -- [V12] superseded_by -> newer memory
    valid_from     timestamptz,                                      -- [V12] query predicate
    valid_until    timestamptz,                                      -- [V12] query predicate
    freshness_class text NOT NULL DEFAULT 'slow_changing'            -- [V12] half-life classes
        CHECK (freshness_class IN ('highly_dynamic','dynamic','slow_changing','stable')),
    salience       double precision CHECK (salience BETWEEN 0 AND 1),  -- [V12] S_salience in compiler scoring
    utility        double precision CHECK (utility BETWEEN 0 AND 1),   -- [V12] S_utility in compiler scoring
    source_run_id  uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,  -- [DERIVED]
    search_tsv     tsvector,                                         -- [V12] PostgreSQL FTS is a named source of truth
    trace_id       char(32),                                         -- [V11]
    created_at     timestamptz NOT NULL DEFAULT now()                -- [V11]
);

CREATE INDEX memories_fts_idx ON continuum.memories USING gin (search_tsv);  -- [DERIVED]
CREATE INDEX memories_workspace_status_idx
    ON continuum.memories (workspace_id, status)
    WHERE invalidated_at IS NULL;                                    -- [DERIVED] matches the source query shape
```

`memory_embeddings` is the one table with complete source DDL. Reproduced
**verbatim**. `[V12]`

```sql
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
```

`memory_edges` follows the v1.1 `knowledge_edges` shape, which v1.0 and v1.1
state identically. `[V11]`

```sql
CREATE TABLE continuum.memory_edges (
    id            uuid PRIMARY KEY,                                  -- [V11] knowledge_edges.id
    workspace_id  uuid NOT NULL                                      -- [V11]
        REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    source_type   text NOT NULL,                                     -- [V11]
    source_id     uuid NOT NULL,                                     -- [V11]
    relation      text NOT NULL,                                     -- [V11]
    target_type   text NOT NULL,                                     -- [V11]
    target_id     uuid NOT NULL,                                     -- [V11]
    weight        double precision NOT NULL DEFAULT 1,               -- [V11]
    valid_from    timestamptz,                                       -- [V11]
    valid_until   timestamptz,                                       -- [V11]
    created_at    timestamptz NOT NULL DEFAULT now()                 -- [V11]
);

-- [DERIVED] v1.2 caps graph traversal at path length <= 2 with hop decay 0.65
CREATE INDEX memory_edges_source_idx
    ON continuum.memory_edges (workspace_id, source_type, source_id);
CREATE INDEX memory_edges_target_idx
    ON continuum.memory_edges (workspace_id, target_type, target_id);
```

### 3.7 Failures

Reproduced from the v1.1 typed `FailureRecord`. `[V11]`

```sql
CREATE TABLE continuum.failures (
    id                    uuid PRIMARY KEY,                          -- [V12] named table
    workspace_id          uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id                uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    task_type             text NOT NULL,                             -- [V11] FailureRecord.task_type
    observed_failure      text NOT NULL,                             -- [V11]
    expected_behavior     text NOT NULL,                             -- [V11]
    root_cause            text,                                      -- [V11] nullable in source
    contributing_factors  text[] NOT NULL DEFAULT '{}',              -- [V11]
    missed_signals        text[] NOT NULL DEFAULT '{}',              -- [V11]
    corrective_rule       text,                                      -- [V11] nullable in source
    regression_test_id    text,                                      -- [V11] nullable in source
    severity              integer NOT NULL,                          -- [V11] FailureRecord.severity
    trace_id              char(32),                                  -- [V11]
    created_at            timestamptz NOT NULL DEFAULT now()         -- [V11]
);
```

### 3.8 Tools

Column set follows the v1.2 tool manifest JSON Schema. `[V12]`

```sql
CREATE TABLE continuum.tools (
    id            uuid PRIMARY KEY,                                  -- [V12] named table
    workspace_id  uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    name          text NOT NULL                                      -- [V12] manifest pattern, verbatim
        CHECK (name ~ '^[a-z0-9][a-z0-9._-]{2,127}$'),
    purpose       text NOT NULL CHECK (length(purpose) >= 8),        -- [V12] manifest minLength
    status        text NOT NULL DEFAULT 'active',                    -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now(),                -- [V11]
    UNIQUE (workspace_id, name)                                      -- [DERIVED]
);

CREATE TABLE continuum.tool_versions (
    id                  uuid PRIMARY KEY,                            -- [V12] named table
    tool_id             uuid NOT NULL REFERENCES continuum.tools(id) ON DELETE CASCADE,
    workspace_id        uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    version             text NOT NULL                                -- [V12] manifest semver pattern, verbatim
        CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
    risk_level          smallint NOT NULL                            -- [V12] manifest 0..4
        CHECK (risk_level BETWEEN 0 AND 4),
    side_effect         continuum.side_effect NOT NULL,              -- [V12]
    reversible          boolean,                                     -- [V12]
    idempotency_required boolean NOT NULL,                           -- [V12]
    idempotency_strategy continuum.idempotency_strategy NOT NULL,    -- [V12]
    permissions         jsonb NOT NULL,                              -- [V12] network/filesystem/secrets required
    resources           jsonb NOT NULL,                              -- [V12] timeout_seconds/cpu_millis/memory_mb/pids
    approval_required   boolean NOT NULL,                            -- [V12]
    input_schema        jsonb NOT NULL,                              -- [V12]
    output_schema       jsonb NOT NULL,                              -- [V12]
    provenance          jsonb,                                       -- [V12]
    image_digest        text,                                        -- [V12] "0 active tools lacking manifest/digest"
    manifest_hash       char(64) NOT NULL,                           -- [DERIVED]
    promotion_stage     continuum.promotion_stage NOT NULL DEFAULT 'proposed',  -- [V12] pipeline
    created_at          timestamptz NOT NULL DEFAULT now(),          -- [V11]
    UNIQUE (tool_id, version),                                       -- [DERIVED]
    -- [V12] risk 3-4 require human approval by default
    CHECK (risk_level < 3 OR approval_required IS TRUE)
);

CREATE TABLE continuum.tool_executions (
    id                uuid PRIMARY KEY,                              -- [V12] named table
    workspace_id      uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    tool_version_id   uuid NOT NULL REFERENCES continuum.tool_versions(id),
    run_id            uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,
    idempotency_key   text NOT NULL,                                 -- [V12] ActivityContext.idempotency_key
    status            text NOT NULL,                                 -- [DECISION]
    exit_code         integer,                                       -- [V12] ExecResult.exit_code
    wall_ms           integer,                                       -- [V12] ExecResult.wall_ms
    cpu_ms            integer,                                       -- [V12] ExecResult.cpu_ms
    max_rss_bytes     bigint,                                        -- [V12] ExecResult.max_rss_bytes
    stdout_artifact_id uuid,                                         -- [V12] ExecResult.stdout_artifact_id
    stderr_artifact_id uuid,                                         -- [V12] ExecResult.stderr_artifact_id
    approved_by       uuid REFERENCES continuum.users(id),           -- [V12] approval audit completeness 100%
    approved_at       timestamptz,                                   -- [V12]
    trace_id          char(32),                                      -- [V11]
    created_at        timestamptz NOT NULL DEFAULT now(),            -- [V11]
    -- [V12] "0 duplicate effects under redelivery"
    UNIQUE (workspace_id, idempotency_key)
);
```

> The `UNIQUE (workspace_id, idempotency_key)` constraint is `[DERIVED]`, but it
> is the mechanism by which the v1.2 hard gate *"duplicate effects under
> redelivery = 0"* becomes enforceable in the database rather than in
> application code.

### 3.9 Evaluations

```sql
CREATE TABLE continuum.evaluations (
    id            uuid PRIMARY KEY,                                  -- [V12] named table
    workspace_id  uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    suite         text NOT NULL,                                     -- [V12] golden/core, adversarial/prompt-injection, ...
    suite_version text NOT NULL,                                     -- [V12] evaluators are versioned objects
    target_type   text NOT NULL,                                     -- [DERIVED] agent_version | tool_version | model | mutation
    target_id     uuid NOT NULL,                                     -- [DERIVED]
    status        text NOT NULL DEFAULT 'pending',                   -- [DECISION]
    started_at    timestamptz,                                       -- [DECISION]
    completed_at  timestamptz,                                       -- [DECISION]
    created_at    timestamptz NOT NULL DEFAULT now()                 -- [V11]
);

CREATE TABLE continuum.evaluation_results (
    id             uuid PRIMARY KEY,                                 -- [V12] named table
    evaluation_id  uuid NOT NULL REFERENCES continuum.evaluations(id) ON DELETE CASCADE,
    workspace_id   uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    case_id        text NOT NULL,                                    -- [DERIVED] suites are case corpora
    passed         boolean NOT NULL,                                 -- [DECISION]
    score          double precision,                                 -- [V12] continuum_eval_score is a required metric
    metric_name    text NOT NULL DEFAULT 'primary',                 -- [DECISION]
    detail         jsonb NOT NULL DEFAULT '{}'::jsonb,               -- [DECISION]
    created_at     timestamptz NOT NULL DEFAULT now(),               -- [V11]
    UNIQUE (evaluation_id, case_id, metric_name)                     -- [DERIVED]
);
```

### 3.10 Mutations

```sql
CREATE TABLE continuum.mutations (
    id               uuid PRIMARY KEY,                               -- [V12] named table
    workspace_id     uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    class            continuum.mutation_class NOT NULL,              -- [V12] mutation classes, verbatim
    parent_id        uuid REFERENCES continuum.mutations(id),        -- [V12] "full parent/eval/canary/approval/rollback lineage"
    target_type      text NOT NULL,                                  -- [DERIVED]
    target_id        uuid NOT NULL,                                  -- [DERIVED]
    hypothesis       text NOT NULL,                                  -- [V12] coefficients are "versioned hypotheses"
    stage            continuum.promotion_stage NOT NULL DEFAULT 'proposed',  -- [V12] progression
    git_ref          text,                                           -- [V12] Git owns executable evolution
    approved_by      uuid REFERENCES continuum.users(id),            -- [V12] human production promotion only
    approved_at      timestamptz,                                    -- [V12]
    rolled_back_at   timestamptz,                                    -- [V12] rollback must be demonstrated
    created_at       timestamptz NOT NULL DEFAULT now(),             -- [V11]
    -- [V12] fully autonomous production promotion is outside v1.2
    CHECK (stage <> 'promoted' OR approved_by IS NOT NULL)
);

CREATE TABLE continuum.mutation_evaluations (
    mutation_id        uuid NOT NULL REFERENCES continuum.mutations(id) ON DELETE CASCADE,
    evaluation_id      uuid NOT NULL REFERENCES continuum.evaluations(id) ON DELETE CASCADE,
    workspace_id       uuid REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    arm                text NOT NULL CHECK (arm IN ('control','variant')),   -- [DERIVED] experiment arms
    quality_delta_pp   double precision,                             -- [V12] quality delta >= -0.5 pp
    quality_ci_low_pp  double precision,                             -- [V12] lower 95% CI bound
    quality_ci_high_pp double precision,                             -- [V12]
    cost_delta_pct     double precision,                             -- [V12] cost reduction >= 10%
    latency_delta_pct  double precision,                             -- [V12] p95 latency reduction >= 30%
    created_at         timestamptz NOT NULL DEFAULT now(),           -- [V11]
    PRIMARY KEY (mutation_id, evaluation_id, arm)                    -- [DERIVED]
);
```

> The `CHECK (stage <> 'promoted' OR approved_by IS NOT NULL)` constraint is
> `[DERIVED]`, and it is the database-level expression of the single most
> important v1.2 safeguard: *"Fully autonomous production self-modification is
> intentionally excluded from v1.2."*

### 3.11 Artifacts

Column set follows the v1.2 artifact manifest JSON Schema. `[V12]`

```sql
CREATE TABLE continuum.artifacts (
    id                  uuid PRIMARY KEY,                            -- [V12] manifest artifact_id
    workspace_id        uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,
    run_id              uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,  -- [V12] nullable in manifest
    kind                text NOT NULL,                               -- [V12]
    media_type          text NOT NULL,                               -- [V12]
    filename            text,                                        -- [V12] nullable in manifest
    byte_length         bigint NOT NULL CHECK (byte_length >= 0),    -- [V12] minimum 0
    sha256              char(64) NOT NULL                            -- [V12] manifest pattern, verbatim
        CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    storage_provider    text NOT NULL DEFAULT 's3' CHECK (storage_provider = 's3'),  -- [V12] const
    storage_bucket      text NOT NULL,                               -- [V12]
    storage_key         text NOT NULL,                               -- [V12]
    storage_version_id  text,                                        -- [V12] nullable
    encryption_mode     text NOT NULL DEFAULT 'SSE-KMS'              -- [V12] const
        CHECK (encryption_mode = 'SSE-KMS'),
    kms_key_arn         text NOT NULL,                               -- [V12] required
    classification      continuum.artifact_classification NOT NULL,  -- [V12]
    retention_class     continuum.retention_class NOT NULL,          -- [V12]
    delete_after        timestamptz,                                 -- [V12] nullable
    producer_component  text NOT NULL,                               -- [V12] producer.component
    producer_version    text NOT NULL,                               -- [V12] producer.version
    parent_artifact_ids uuid[] NOT NULL DEFAULT '{}',                -- [V12]
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,          -- [V12]
    created_at          timestamptz NOT NULL DEFAULT now()           -- [V12] required
);

CREATE INDEX artifacts_sha_idx ON continuum.artifacts (workspace_id, sha256);  -- [DERIVED]
```

### 3.12 Cost

Column set follows the v1.2 cost model, which states each direct cost produces
provider, SKU, quantity, unit, unit price, timestamp, run, workspace, cost. `[V12]`

```sql
CREATE TABLE continuum.cost_events (
    id            uuid PRIMARY KEY,                                  -- [V12] named table
    workspace_id  uuid NOT NULL REFERENCES continuum.workspaces(id) ON DELETE CASCADE,  -- [V12]
    run_id        uuid REFERENCES continuum.runs(id) ON DELETE SET NULL,  -- [V12]
    provider      text NOT NULL,                                     -- [V12]
    sku           text NOT NULL,                                     -- [V12]
    component     text NOT NULL                                      -- [V12] COGS components
        CHECK (component IN ('model','tool_api','temporal','eks',
                             'sandbox','db','s3','network','observability')),
    quantity      numeric(20,6) NOT NULL,                            -- [V12]
    unit          text NOT NULL,                                     -- [V12]
    unit_price    numeric(20,10) NOT NULL,                           -- [V12]
    cost_usd      numeric(14,6) NOT NULL,                            -- [V12]
    price_catalog_version text NOT NULL,                             -- [V12] versioned catalog, not hard-coded
    occurred_at   timestamptz NOT NULL,                              -- [V12] timestamp
    created_at    timestamptz NOT NULL DEFAULT now()                 -- [V11]
);

CREATE INDEX cost_events_run_idx ON continuum.cost_events (run_id);           -- [DERIVED]
CREATE INDEX cost_events_workspace_time_idx
    ON continuum.cost_events (workspace_id, occurred_at DESC);                -- [DERIVED]
```

---

## 4. Event store

v1.2 states the field list exactly. Types are `[DERIVED]`. The v1.1 `run_events`
table is the direct ancestor and supplies the `BIGSERIAL` ordering column and
the run index. `[V11]`

```sql
CREATE TABLE continuum.events (
    sequence            bigserial PRIMARY KEY,                       -- [V11] run_events.sequence
    event_id            uuid NOT NULL UNIQUE,                        -- [V12] field, [V11] UNIQUE
    workspace_id        uuid NOT NULL REFERENCES continuum.workspaces(id),  -- [V12] field
    run_id              uuid REFERENCES continuum.runs(id),          -- [V12] field
    event_type          text NOT NULL,                               -- [V12] field
    schema_version      integer NOT NULL,                            -- [V12] field, [V11] INTEGER
    aggregate_type      text NOT NULL,                               -- [V12] field
    aggregate_id        uuid NOT NULL,                               -- [V12] field
    causation_event_id  uuid,                                        -- [V12] field
    correlation_id      uuid,                                        -- [V12] field
    actor_type          text NOT NULL,                               -- [V12] field
    actor_id            uuid,                                        -- [V12] field
    trace_id            char(32),                                    -- [V12] field
    payload             jsonb NOT NULL,                              -- [V12] field, [V11] JSONB NOT NULL
    payload_artifact_id uuid,                                        -- [V12] >256 KiB offloads to S3
    previous_hash       char(64),                                    -- [V12] field
    event_hash          char(64) NOT NULL,                           -- [V12] field
    occurred_at         timestamptz NOT NULL,                        -- [V12] field
    ingested_at         timestamptz NOT NULL DEFAULT now()           -- [V12] field
);

CREATE INDEX events_run_idx
    ON continuum.events (run_id, sequence);                          -- [V11] run_events_run_idx
CREATE INDEX events_aggregate_idx
    ON continuum.events (workspace_id, aggregate_type, aggregate_id, sequence);  -- [DERIVED]
```

### 4.1 Append-only enforcement

v1.2 requires the event store be append-only *for application roles*. `[V12]`
The enforcement mechanism is `[DERIVED]`.

```sql
REVOKE UPDATE, DELETE, TRUNCATE ON continuum.events FROM continuum_app;
GRANT INSERT, SELECT ON continuum.events TO continuum_app;

CREATE OR REPLACE FUNCTION continuum.events_reject_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'continuum.events is append-only (attempted %)', TG_OP;
END;
$$;

CREATE TRIGGER events_append_only
    BEFORE UPDATE OR DELETE ON continuum.events
    FOR EACH ROW EXECUTE FUNCTION continuum.events_reject_mutation();
```

### 4.2 Hash chain

v1.2 states the chain detects silent modification of audit history, and requires
`continuum_event_hash_failures_total` as a metric. The canonicalisation is
`[DERIVED]` — the original artifact's exact byte layout is unknown, so this
**must be fixed by ADR before any event is written**, since changing it later
invalidates every existing chain.

```text
event_hash = sha256(
    previous_hash || 0x1F ||
    event_id      || 0x1F ||
    workspace_id  || 0x1F ||
    event_type    || 0x1F ||
    schema_version|| 0x1F ||
    aggregate_type|| 0x1F ||
    aggregate_id  || 0x1F ||
    occurred_at   || 0x1F ||     -- RFC 3339, UTC, microsecond precision
    sha256(payload_canonical_json)
)
```

`previous_hash` is the `event_hash` of the preceding event in the same
`workspace_id` chain, or 64 zero characters for the genesis event. `[DERIVED]`

---

## 5. Row Level Security

v1.2 requires RLS tenant isolation on the production database, with a hard gate
of zero cross-workspace access across 10,000+ attempts. `[V12]`

```sql
-- Applied to every table carrying workspace_id.
-- FORCE ensures the policy also applies to the table owner.
ALTER TABLE continuum.runs              ENABLE ROW LEVEL SECURITY;
ALTER TABLE continuum.runs              FORCE  ROW LEVEL SECURITY;
CREATE POLICY runs_tenant_isolation ON continuum.runs
    USING (workspace_id = continuum.current_workspace_id())
    WITH CHECK (workspace_id = continuum.current_workspace_id());

-- ... repeated identically for:
--   artifacts, agents, agent_versions, model_metrics, evidence, claims,
--   claim_evidence, memories, memory_embeddings, memory_edges, failures,
--   tools, tool_versions, tool_executions, evaluations, evaluation_results,
--   mutations, mutation_evaluations, events, cost_events, workspace_members
```

`users` and `models` are not workspace-scoped and are governed by grants rather
than RLS. `[DECISION]`

Because `continuum.current_workspace_id()` returns `NULL` when `app.workspace_id`
is unset, every policy fails closed. `[V12]`

---

## 6. Dependency baseline

### 6.1 Pinned in v1.2 — reproduce exactly `[V12]`

```hcl
terraform { required_version = "= 1.14.0" }
hashicorp/aws          = "= 6.60.0"
hashicorp/kubernetes   = "= 2.38.0"
hashicorp/helm         = "= 3.2.0"
temporalio/temporalcloud = "= 1.5.0"
kislerdm/neon          = "= 0.15.0"    # community provider; no auto-upgrade in CI
```

```text
PostgreSQL           18
Amazon EKS           1.36
pgvector HNSW        m=16, ef_construction=64, ef_search=80, iterative_scan=strict_order
Embedding profile    text-embedding-3-small, 512 dims, cosine
Model profiles       gpt-5-mini-2025-08-07 (economical), gpt-5.5-2026-04-23 (high_reasoning)
```

### 6.2 Libraries named by v1.2, versions not stated

The library set is `[V12]` — each is named or used in v1.2 text. **The versions
are `[DECISION]` and are deliberately left unpinned here rather than invented.**

| Library | Evidence in v1.2 | Version |
|---|---|---|
| `temporalio` | Temporal Python SDK named throughout | pinned in-tree at `1.31.0` `[DECISION]` |
| `alembic` | migration Job runs `alembic upgrade head` | **unpinned** |
| `pydantic` | all Activity and model contracts are `BaseModel` | **unpinned** |
| `openai` | OpenAI Python client retry behaviour discussed | **unpinned** |
| `opentelemetry-*` | OTel is the named telemetry layer | **unpinned** |
| `boto3` / `psycopg` | S3 and PostgreSQL are named sources of truth | **unpinned** |

> Inventing version numbers here would be exactly the failure
> `CONT-LOCAL-GOV-001` prohibits. These must be pinned at implementation time
> and recorded in `uv.lock`, not asserted as recovered specification.

---

## 7. Temporal definitions

### 7.1 Stated in v1.2 — reproduced here `[V12]`

The artifact this replaces was expected to carry the Temporal definitions, so
they are reproduced rather than cross-referenced. The v1.2 report is not
committed to this repository, and pointing at an uncommitted document would
leave the replacement incomplete in exactly the way that created `SRC-001`.

**Namespaces**

| Environment | Namespace | Retention | HA |
|---|---|---:|---|
| Local | `continuum-dev` | 3 days | No |
| Staging | `continuum-staging` | 7 days | Provider default |
| Production | `continuum-prod` | 30 days | Yes |

**Task queues**

| Queue | Responsibility | Min workers | Scale policy |
|---|---|---:|---|
| `continuum.control` | Workflow coordination | 2 | HPA / Worker Controller |
| `continuum.interactive` | Agent/model/context work | 2 | KEDA + Worker Controller |
| `continuum.batch` | Evals, embeddings, memory, Watchers | 0 | KEDA scale-to-zero |
| `continuum.actions` | External side effects | 2 | HPA; **no** scale-to-zero |
| `continuum.sandbox` | Isolated computation | 0 | KEDA with hard maximum |
| `continuum.gpu` | Optional GPU work | 0 | Disabled until configured |

**Priority** — 1 is highest

```text
1 = action completion / approval / critical recovery
2 = interactive
3 = standard
4 = evaluation / memory / watcher
5 = bulk / mutation / non-urgent ingestion
```

**Fairness key** — `w:<base32(sha256(workspace_id))[0:26]>`, weighted by plan:
internal/enterprise 2.0, team/builder 1.5, pro/personal 1.0, free 0.5.

**Workflow catalog**

| Workflow | Continue-As-New condition |
|---|---|
| `ReasoningWorkflow` | >8,000 history events or recurring execution >24h |
| `EvaluationWorkflow` | >8,000 events |
| `ActionWorkflow` | normally completes directly |
| `IngestionWorkflow` | each 5,000-document epoch |
| `ToolPromotionWorkflow` | each promotion epoch |
| `MutationWorkflow` | each experiment epoch |

**Retry policies**

```python
MODEL_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=2), backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=20), maximum_attempts=3,
    non_retryable_error_types=["InvalidInputError", "ProviderBadRequestError",
                               "PolicyDeniedError", "BudgetExceededError"])

IO_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=1), backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=30), maximum_attempts=5)

SIDE_EFFECT_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=2), backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=30), maximum_attempts=3,
    non_retryable_error_types=["PolicyDeniedError", "HumanApprovalRejected",
                               "NonIdempotentActionError", "InvalidInputError"])

SANDBOX_RETRY = RetryPolicy(
    initial_interval=timedelta(seconds=5), backoff_coefficient=2.0,
    maximum_interval=timedelta(seconds=30), maximum_attempts=2)
```

**Error taxonomy**

| Error | Retry? | System behavior |
|---|---|---|
| `InvalidInputError` | No | terminal / config / user correction |
| `PolicyDeniedError` | No | emit denial event |
| `BudgetExceededError` | No | stop expansion, synthesize best available |
| `ProviderBadRequestError` | No | configuration alert |
| `ProviderRateLimitError` | Yes | bounded retry |
| `ProviderUnavailableError` | Yes | bounded retry then provider failover |
| `DatabaseConflictError` | Yes | repeat idempotent transaction |
| `ArtifactIntegrityError` | Once | quarantine after repeat |
| `ToolExecutionError` | Conditional | manifest policy |
| `NonIdempotentActionError` | No | block side effect |
| `HumanApprovalRejected` | No | complete workflow rejected |
| `SandboxPolicyError` | No | security event + quarantine |
| `StaleVersionError` | No | compatible-worker routing |
| `CancellationRequested` | No | cooperative cancellation |

Worker versioning ramps 5% → 25% → 50% → 100% with rollback at every stage. The
Activity I/O contracts (`ActivityContext`, `CompileContextInput`,
`ContextBundle`, `ExecuteAgentInput`, `AgentExecutionOutput`) are stated in v1.2
and implemented in `services/orchestrator/temporal/`.

### 7.2 Activity timeouts — the one item explicitly lost

The v1.2 report states: *"Activity timeouts are defined in the downloadable core
artifact."* This is the only content the report explicitly delegates and does not
restate. Everything in this section is therefore `[DECISION]`.

The values below match what is already implemented in
`services/orchestrator/temporal/policies.py`, so this section records existing
in-tree choices rather than introducing new ones.

| Class | start_to_close | schedule_to_close | heartbeat | max attempts |
|---|---:|---:|---:|---:|
| `model_call` | 120 s | 300 s | — | 3 |
| `retrieval` | 60 s | 180 s | — | 3 |
| `tool_call` | 120 s | 300 s | — | 2 |
| `long_running` | 3600 s | 7200 s | 30 s | 2 |

Constraints these must satisfy, all `[V12]`:

- `maximum_attempts` must be explicitly capped on paid model/API operations,
  because Temporal's default retry behaviour is effectively unbounded.
- Long Activities MUST heartbeat; heartbeat details MUST NOT contain credentials
  or large data bodies.
- Retry intervals follow the four named policies — `MODEL_RETRY`, `IO_RETRY`,
  `SIDE_EFFECT_RETRY`, `SANDBOX_RETRY` — whose `initial_interval`,
  `backoff_coefficient` and `maximum_interval` **are** stated in v1.2 and are
  not currently encoded in `ActivityPolicy`. See finding F-07.

---

## 8. Traceability summary

| Tag | Count (approx.) | Disposition |
|---|---:|---|
| `[V12]` | ~120 declarations | Citable as v1.2 |
| `[V11]` | ~45 declarations | Predecessor text; cite as v1.0/v1.1 |
| `[DERIVED]` | ~35 declarations | Inferred from cited v1.2 invariants |
| `[DECISION]` | ~30 declarations | **Requires ADR approval before use** |

### Decisions requiring ADR approval before implementation

**Ordered by consequence:**

1. **Event hash canonicalisation** (§4.2) — highest priority. Changing this
   after any event is written invalidates every existing chain, so it must be
   fixed before the event store takes its first write.
2. **Activity timeout values** (§7.2) — currently in-tree without an ADR.
3. **Language dependency versions** (§6.2) — deliberately unpinned here.
4. **`users` / `models` exemption from RLS** (§5).
5. **Built-in agent visibility** (§5) — `workspace_id IS NULL` rows are readable
   by every tenant under a dedicated read policy.
6. **Role and function names** — already approved under ADR-0001.

**Complete enumeration.** The list below is generated from the
`[DECISION]` tags in `continuum_v1.2_core_schema.derived.sql`, so it cannot
drift from the executable schema. Every entry needs approval before that
declaration is relied upon.

| # | Location | Declaration |
|---:|---|---|
| 1 | `schema-level` | `CREATE EXTENSION IF NOT EXISTS citext;` |
| 2 | `schema-level` | `CREATE TYPE continuum.memory_type AS ENUM (` |
| 3 | `schema-level` | `CREATE TYPE continuum.run_status AS ENUM (` |
| 4 | `users` | `email        citext NOT NULL UNIQUE` |
| 5 | `users` | `display_name text` |
| 6 | `users` | `status       text NOT NULL DEFAULT 'active'` |
| 7 | `users` | `updated_at   timestamptz NOT NULL DEFAULT now()` |
| 8 | `workspaces` | `name       text NOT NULL` |
| 9 | `workspaces` | `status     text NOT NULL DEFAULT 'active'` |
| 10 | `workspaces` | `updated_at timestamptz NOT NULL DEFAULT now()` |
| 11 | `workspace_members` | `role         text NOT NULL DEFAULT 'member'` |
| 12 | `runs` | `created_by      uuid REFERENCES continuum.users(id)` |
| 13 | `runs` | `status          continuum.run_status NOT NULL DEFAULT 'accepted'` |
| 14 | `runs` | `started_at      timestamptz` |
| 15 | `runs` | `completed_at    timestamptz` |
| 16 | `agents` | `name         text NOT NULL` |
| 17 | `agents` | `status       text NOT NULL DEFAULT 'active'` |
| 18 | `agents` | `UNIQUE (workspace_id, name)` |
| 19 | `agent_versions` | `config             jsonb NOT NULL DEFAULT '{}'::jsonb` |
| 20 | `model_metrics` | `window_start      timestamptz NOT NULL` |
| 21 | `model_metrics` | `window_end        timestamptz NOT NULL` |
| 22 | `model_metrics` | `sample_count      integer NOT NULL CHECK (sample_count >= 0)` |
| 23 | `claim_evidence` | `weight       double precision CHECK (weight BETWEEN 0 AND 1)` |
| 24 | `tools` | `status       text NOT NULL DEFAULT 'active'` |
| 25 | `tool_executions` | `status             text NOT NULL` |
| 26 | `evaluations` | `status        text NOT NULL DEFAULT 'pending'` |
| 27 | `evaluations` | `started_at    timestamptz` |
| 28 | `evaluations` | `completed_at  timestamptz` |
| 29 | `evaluation_results` | `passed        boolean NOT NULL` |
| 30 | `evaluation_results` | `metric_name   text NOT NULL DEFAULT 'primary'` |
| 31 | `evaluation_results` | `detail        jsonb NOT NULL DEFAULT '{}'::jsonb` |

### Known divergences from v1.2 already in-tree

These are separate findings, not part of this reconstruction: Temporal task
queue names and the priority scale (F-06), retry backoff shape (F-07), and
worker deployment queue coverage (F-08).

---

## 9. What this document does not do

It does not close `SRC-001`. Issue #2's second close criterion requires that
reconstructed detail be *"approved through an ADR with traceability to v1.2"*.
This artifact supplies the traceability. The ADRs and the approval are separate
and remain outstanding.

It does not authorise `FND-DB-DOMAIN` to proceed. That package stays `blocked`
until the decisions in §8 are approved.
