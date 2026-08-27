#!/usr/bin/env bash
# Concurrent-writer check for the derived event store's hash chain.
#
# A single psql script cannot exercise this: the defect it targets is a race
# between the allocation of the ordering value and the read of the chain head.
# With the ordering value allocated by a column default -- outside the trigger's
# per-workspace advisory lock -- two writers can take positions N and N+1,
# commit in the order N+1 then N, and leave position N chained to position N+1.
# Verified in sequence order that chain reads as broken.
#
# Each writer runs its inserts as separate autocommit statements, so the lock is
# taken and released repeatedly and the writers genuinely interleave.

set -euo pipefail

WORKSPACE='00000000-0000-0000-0000-0000000000cc'
WRITERS="${WRITERS:-4}"
EVENTS_PER_WRITER="${EVENTS_PER_WRITER:-25}"
EXPECTED=$((WRITERS * EVENTS_PER_WRITER))

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

psql -v ON_ERROR_STOP=1 -q -c \
    "INSERT INTO continuum.workspaces (id, name)
     VALUES ('${WORKSPACE}', 'concurrency-ws')
     ON CONFLICT (id) DO NOTHING;"

for ((n = 1; n <= EVENTS_PER_WRITER; n++)); do
    cat >> "$workdir/writer.sql" <<SQL
INSERT INTO continuum.events (
    event_id, workspace_id, event_type, schema_version,
    aggregate_type, aggregate_id, actor_type, payload, occurred_at
) VALUES (
    gen_random_uuid(), '${WORKSPACE}', 'ConcurrentEvent', 1, 'workspace',
    '${WORKSPACE}', 'system', jsonb_build_object('n', ${n}), now()
);
SQL
done

echo "starting ${WRITERS} concurrent writers x ${EVENTS_PER_WRITER} events"
pids=()
for ((w = 1; w <= WRITERS; w++)); do
    psql -v ON_ERROR_STOP=1 -q -f "$workdir/writer.sql" &
    pids+=("$!")
done

failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
done
if [[ "$failed" -ne 0 ]]; then
    echo "a concurrent writer failed" >&2
    exit 1
fi

# Passed as session GUCs rather than psql :variables: psql does not interpolate
# variables inside dollar-quoted strings, so workspace would reach the server
# literally.
PGOPTIONS="-c continuum.test_workspace=${WORKSPACE} -c continuum.test_expected=${EXPECTED}" \
psql -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    workspace uuid    := current_setting('continuum.test_workspace')::uuid;
    expected  integer := current_setting('continuum.test_expected')::integer;
    total    integer;
    breaks   integer;
    genesis  integer;
    distinct_hashes integer;
BEGIN
    SELECT count(*) INTO total
      FROM continuum.events WHERE workspace_id = workspace;
    IF total <> expected THEN
        RAISE EXCEPTION 'expected % events, found %', expected, total;
    END IF;

    -- Every non-genesis event must chain to the event immediately before it in
    -- sequence order. This is the assertion the race breaks.
    SELECT count(*) INTO breaks
      FROM (
        SELECT previous_hash,
               lag(event_hash) OVER (ORDER BY sequence) AS prior
          FROM continuum.events
         WHERE workspace_id = workspace
      ) c
     WHERE c.prior IS NOT NULL AND c.previous_hash IS DISTINCT FROM c.prior;
    IF breaks <> 0 THEN
        RAISE EXCEPTION
            'hash chain broken at % of % events written concurrently', breaks, total;
    END IF;

    SELECT count(*) INTO genesis
      FROM continuum.events
     WHERE workspace_id = workspace AND previous_hash IS NULL;
    IF genesis <> 1 THEN
        RAISE EXCEPTION 'expected exactly one genesis event, found %', genesis;
    END IF;

    SELECT count(DISTINCT event_hash) INTO distinct_hashes
      FROM continuum.events WHERE workspace_id = workspace;
    IF distinct_hashes <> total THEN
        RAISE EXCEPTION 'duplicate event hashes: % distinct across % events',
            distinct_hashes, total;
    END IF;

    RAISE NOTICE
        'concurrent writers: % events, chain intact in sequence order, one genesis',
        total;
END
$$;
SQL
