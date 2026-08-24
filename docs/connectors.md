# Connector Use Policy

Continuum may use connected tools when they reduce implementation risk, improve verification, or remove undifferentiated infrastructure work. Connector availability does not change the v1.2 architecture unless measured evidence justifies an ADR change.

## Automatically usable for low-risk reads / verification

| Connector | Project use |
| --- | --- |
| GitHub | Source control, branches, PRs, CI, code review, release evidence. Primary implementation interface. |
| Files | Read the governing Continuum specifications and supporting project documents. |
| Exa / Parallel Search | Current implementation documentation and public technical research when first-party freshness is needed. |
| Neon Postgres | Read project/database metadata, inspect schema, query diagnostics, and later validate database behavior. Resource creation or destructive SQL remains phase-gated. |
| Vercel | Inspect deployment/docs/logs and later preview the control-plane UI. Production deployment remains release-gated. |
| Required Fields Validator | Validate structured contracts where it removes ambiguity. |
| Requirements Extractor | Cross-check explicit requirements when converting project documentation into machine-verifiable work. |

## Conditional / later-phase connectors

| Connector | Use condition |
| --- | --- |
| ClickHouse | Add only when analytical/telemetry load measurably harms PostgreSQL or volume justifies a derived analytics store. |
| Wolfram | Quantitative validation, calibration, statistics, or mathematical checks where independent computation helps. |
| Mobbin | UI/UX reference research for the control plane; never a source of system truth. |
| TinyFish | Browser-based validation/workflows when ordinary APIs or direct web retrieval are insufficient. |
| Consensus / SciSpace / Sider Scholar | Academic literature review for evaluation, agent/reasoning, safety, or calibration research. |
| YepCode | Candidate custom integration/tool experiments only after the Tool/Action safety model is proven. |
| Opscotch | Operational specification/validation if it provides concrete value during runbook or infrastructure authoring. |
| Gmail / Google Calendar / Google Contacts | Project communications/operations only when an explicit workflow needs them. |
| Readwise | Reference retrieval only if project research is intentionally stored there. |
| Agent Ready | Public-site agent-readability checks after a public Continuum interface exists. |
| Mnemom | Optional agent-trust metadata research; not part of the v1.2 source-of-truth model. |

## Deliberately not used as Continuum infrastructure

- Supabase, WoWSQL, and other database platforms: v1.2 selects Neon PostgreSQL unless an ADR gate proves the choice no longer fits.
- Alternative recommendation/search workspaces that do not serve the implementation plan.
- Finance, sports, shopping, music, image/video, game, coupon, grocery, personality, and unrelated consumer connectors.

## Risk rule

Low-risk read/search/validation actions may be invoked without an additional user confirmation. Writes that create billable cloud infrastructure, alter persistent databases, deploy production services, modify credentials/permissions, send communications, or trigger external side effects remain subject to the appropriate Continuum phase gate and explicit safety/approval requirements.
