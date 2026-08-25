# Temporal worker rollback

Use this runbook when a newly activated `continuum-orchestrator` Worker
Deployment Version is unhealthy. It changes routing in Temporal; it does not
modify repository history or merge a pull request.

## Preconditions

- A previous compatible build is deployed and polling every required task queue.
- The previous build passed the replay suite against representative histories.
- The operator has Temporal namespace access and records the incident/approval.
- `temporal` CLI is version 1.4.1 or newer and targets the intended namespace.

## Procedure

1. Record the current and rollback builds.

   ```bash
   export CONTINUUM_DEPLOYMENT='continuum-orchestrator'
   export CONTINUUM_BAD_BUILD='<current-build-id>'
   export CONTINUUM_ROLLBACK_BUILD='<previous-compatible-build-id>'
   temporal worker deployment describe --name="$CONTINUUM_DEPLOYMENT"
   ```

2. Confirm the rollback build is polling and healthy in deployment output and
   application telemetry. Stop if it is absent or if its replay evidence is
   stale.

3. With human approval, make the previous build current.

   ```bash
   temporal worker deployment set-current-version \
     --deployment-name "$CONTINUUM_DEPLOYMENT" \
     --build-id "$CONTINUUM_ROLLBACK_BUILD"
   ```

4. Verify routing and error-rate recovery.

   ```bash
   temporal worker deployment describe --name="$CONTINUUM_DEPLOYMENT"
   temporal workflow describe -w '<representative-workflow-id>'
   ```

5. Keep the bad build available until affected pinned Workflows are assessed.
   Do not force pinned executions onto an incompatible build. Use a versioning
   override or Reset-with-Move only under a separate incident plan with replay
   evidence for the target build.

6. Record command output, timestamps, build IDs, affected Workflow IDs, and the
   approving operator in the incident evidence.

## Abort criteria

- Rollback build is not polling all required task queues.
- Replay verification fails for the rollback build.
- The proposed target cannot execute histories pinned to the bad build.
- Namespace or deployment identity is ambiguous.

If any criterion is met, stop routing changes and escalate to the incident
owner. Never delete Worker Deployment Versions during the rollback itself.
