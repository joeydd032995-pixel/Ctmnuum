# Temporal replay histories

The Foundation replay suite creates representative histories in an ephemeral
Temporal test environment, then replays them with `temporalio.worker.Replayer`.
It covers both the current patched history and a pre-patch history produced by
the original `continuum.foundation.workflow` command sequence.

Production history fixtures will be added here only after a real namespace is
available. They must be exported without payloads containing secrets or tenant
data and must retain their originating SDK/server version metadata.
