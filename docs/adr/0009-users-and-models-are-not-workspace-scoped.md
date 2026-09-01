# ADR-0009: `users` and `models` are governed by grants, not by RLS

- **Status:** Accepted for Foundation implementation
- **Date:** 2026-09-01
- **Related:** `FND-SPEC-002`; ADR-0006 (every tenant-scoped row names its workspace)
- **Closes:** `[DECISION]` 7 of the companion document

## Context

v1.2 requires RLS tenant isolation with a hard gate of zero cross-workspace
access. Every table carrying `workspace_id` has `ENABLE` and `FORCE` row-level
security and a policy comparing that column against
`continuum.current_workspace_id()`.

Three tables do not: `users`, `models` and `event_schemas`. Verify assertion 5
carries them in an exemption list, which until now was an untagged decision — an
exemption from the gate v1.2 states most loudly, asserted in a test and approved
nowhere.

## Decision

**A table is exempt from RLS only if it has no tenant dimension at all. It is
then governed by grants, and the grant is the whole control.**

### `users`

A person is not owned by a workspace. `workspace_members` is the tenancy
relation — `(workspace_id, user_id)` with its own RLS — and it is what scopes a
user *to* a workspace. Putting `workspace_id` on `users` would either duplicate
that relation or forbid a person belonging to two workspaces.

`continuum_app` holds `SELECT` only. It cannot create, rename or disable a
person; that is an administrative act through `continuum_migration`.

Residual risk, stated: **any role that can read `users` can read every user
row.** Display names and emails are not tenant-partitioned. If that becomes
unacceptable, the fix is a view or column-level grants, not an RLS policy on a
column that should not exist.

### `models`

A model is a property of the platform, not of a tenant: provider, model id,
snapshot, capabilities, and a status the router filters on. Two workspaces
routing to the same snapshot must see the same row, or the routing decision is
not reproducible across tenants.

Per-tenant *measurements* about models are tenant-scoped, and live in
`model_metrics`, which does carry `workspace_id` and is under RLS. The split is
deliberate: the catalogue is shared, the observations are not.

`continuum_app` holds `SELECT` only. Registering or deprecating a model is
administrative.

### `event_schemas`

Exempt for the same reason and recorded already: the registry defines which
payload shapes exist, and a tenant that could not read it could not write an
event. It is read-only to the application.

## What would have to change

If either table ever gains a tenant dimension — a per-workspace user profile, a
tenant-private model — the correct move is a **new tenant-scoped table** with
its own `workspace_id`, RLS, and a composite foreign key per ADR-0006. Not an
RLS policy retrofitted onto a shared table, which would either hide rows the
router needs or expose rows it does not.

## Consequences

- The exemption list in verify assertion 5 is now an approved decision rather
  than an assertion nobody sanctioned.
- Adding a fourth table to that list requires amending this ADR. The list is
  short on purpose: it is the set of places where the v1.2 tenancy gate is
  answered by grants instead of policies, and it should be auditable at a
  glance.
- ADR-0006 removed the last case of a nullable `workspace_id` meaning "shared".
  These three tables are shared by *not having the column*, which is the
  distinction that makes the tenancy rule checkable — assertion 33 keys off
  exactly that.

## Verification

- **Assertion 5** — RLS enabled and forced on every table carrying
  `workspace_id`, with these three named as the exemption. Breaking it: an
  ordinary tenant table with RLS switched off is reported.
- **Assertion 33** — every foreign key naming a tenant-scoped parent is
  qualified by `workspace_id`, matched by ordinal. References to `users`,
  `models` and `event_schemas` are excluded *because those tables have no
  `workspace_id`*, not by an exemption list — the structure decides.
- **Assertion 24** — no operational role can delete a domain row, so the grants
  named here are the whole of what `continuum_app` may do.

## Provenance

v1.2 states the tenancy gate and that RLS enforces it: `[V12]`. That these three
tables sit outside tenant scope, and that grants govern them instead, is
`[DECISION: ADR-0009]`.
