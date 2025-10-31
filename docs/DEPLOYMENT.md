# Deployment Guide

This document contains practical production deployment guidance for the `Broadway.QuantumFlowProducer` package. It covers required environment configuration, database and queue setup, monitoring, scaling guidance, troubleshooting steps, and rollback procedures.

## Overview

The producer integrates Broadway with QuantumFlow-backed workflows using PostgreSQL as the durable queue. Production deployments must ensure durable storage, correct QuantumFlow configuration, resource lock handling (e.g., GPUs), monitoring, and an operational rollout/rollback plan.

## Prerequisites

- PostgreSQL (primary) reachable by the app and QuantumFlow.
- QuantumFlow library installed and available to your runtime.
- Ecto repo configured and connection pool sized appropriately.
- Nix-based reproducible build/dev shells are recommended to match CI and production runtimes.
- Operational access to resource lock mechanism (DB advisory locks or dedicated locks table) if using resource_hints (GPU).

## Environment variables

Recommended variables (do not commit secrets):

- DATABASE_URL or ECTO_REPO-specific DSN (e.g., postgresql://user:pass@host:5432/db)
- POOL_SIZE (Ecto pool size)
- PGFLOW_TIMEOUT_MS (default 300000)
- PGFLOW_RETRIES (default 3)
- BROADWAY_CONCURRENCY (per-instance concurrency)
- BROADWAY_BATCH_SIZE (batch size used by producer)
- GPU_LOCK_TABLE (if using table-based locks)
- SECRET_BACKEND configuration (secrets manager / vault endpoint)

Load sensitive values via your secret manager or Nix deployment config.

## Database & Queue setup

- Create queue tables with JSONB payload columns, status, inserted_at, updated_at, and failure_reason.
- Add indexes on (status, inserted_at) to make pending job selection efficient.
- Provide migrations for every queue used by your pipelines.

Example migration snippet:

```sql
CREATE TABLE IF NOT EXISTS embedding_jobs (
  id BIGSERIAL PRIMARY KEY,
  data JSONB NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  status VARCHAR(20) DEFAULT 'pending' NOT NULL,
  inserted_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  failure_reason TEXT
);
CREATE INDEX idx_embedding_jobs_status_inserted_at ON embedding_jobs (status, inserted_at);
```

## QuantumFlow configuration

- Use distinct workflow_name for each logical producer to avoid collisions.
- Tune PBflow workflow timeout and retries:
  - PGFLOW_TIMEOUT_MS: Set to slightly above expected maximum job runtime.
  - PGFLOW_RETRIES: Number of retries before permanent failure handling.
- Ensure QuantumFlow has permissions to read/update queue tables and use advisory locks if required.

## Resource locks (GPUs, exclusive resources)

- Prefer Postgres advisory locks or a lightweight locks table with bounded wait time.
- Implement timeouts and fallback behavior when lock acquisition fails (avoid indefinite blocking).
- Monitor lock contention as part of operational dashboards.

## Monitoring & Observability

Instrument and monitor:

- Queue depth: SELECT COUNT(*) FROM <queue> WHERE status = 'pending'
- Processing throughput: completed jobs per minute
- Error rate: failed jobs / total jobs
- End-to-end latency: time from inserted_at → completed/failed
- QuantumFlow workflow health: restarts, failures, running workflows count
- Resource lock metrics: lock waiters, lock acquisition rate

Recommended tools: Prometheus + Grafana for metrics, alerting for thresholds (queue depth, error rate, workflow crash rate).

Suggested alerts:
- Queue depth > N for M minutes
- Error rate > X% over Y minutes
- Workflow crash frequency spike

## Scaling guidance

- Horizontal scaling: run multiple identical pipeline instances sharing the same queue. Tune per-instance concurrency based on CPU and DB capacity.
- Batch size: increase for higher throughput, monitor memory usage.
- Database:
  - Ensure write operations (ack/requeue) go to primary.
  - Consider read replicas for read-heavy, non-mutating reads but avoid stale data for dequeue logic.
- Start with conservative concurrency (1-2x cores) and ramp up while observing metrics.

## Rollout strategy

- Canary / phased rollout:
  1. Deploy a single instance with production config.
  2. Validate metrics (queue depth, latency, error rate).
  3. Gradually increase instance count and concurrency.
- Fallback plan:
  - Scale down new producer instances.
  - Optionally switch pipelines to a safe fallback producer (e.g., DummyProducer) that drains or pauses consumption.
  - Preserve pending jobs via DB snapshot/export before destructive migration.

## Troubleshooting

Common issues and steps:

- Producer fails to start (workflow failed):
  - Check QuantumFlow and DB connectivity and permissions.
  - Validate workflow_name uniqueness.
  - Inspect app logs for stack traces.

- Messages not yielded:
  - Verify queue schema and pending jobs exist.
  - Check QuantumFlow workflows are running and not stuck.
  - Ensure indexes on status/inserted_at to avoid full table scans.

- High latency / low throughput:
  - Increase concurrency and batch_size, monitor DB load.
  - Check connection pool exhaustion.
  - Add appropriate DB indexes.

- Resource hint failures (GPU/locks):
  - Confirm resource availability and lock table/advisory lock correctness.
  - Implement and tune lock acquisition timeouts.

Operational commands (examples):
- Check pending job count:
  - psql -c "SELECT status, COUNT(*) FROM embedding_jobs GROUP BY status;"
- Inspect Broadway producer state (iex):
  - :sys.get_state(Broadway.QuantumFlowProducer)

## Rollback procedures

- On severe regression:
  1. Scale down the new producer instances to stop new consumption.
  2. If needed, restart previous stable release and its producer.
  3. Ensure pending jobs are intact in DB and not lost by partial acks.
  4. If schema changes were applied, follow reverse migration steps if safe (prefer additive migrations).

## Operational runbook

- Pre-deploy:
  - Run DB migrations in a controlled manner.
  - Verify backup and restore tested.
  - Ensure Nix environment and release build reproduceable.

- Post-deploy validation:
  - Validate workflow registration in QuantumFlow.
  - Verify queue depth trends and latency.
  - Check for increased error rates.

## Notes about benchmarking

- The included `bench/bench.exs` performs in-memory microbenchmarks using Benchee to compare push/iteration paths.
- For end-to-end performance (DB, QuantumFlow, GPU-bound tasks) run integration benchmarks in a staging environment that mirrors production hardware and DB.

## Contact & escalation

- Add owners and on-call contacts for pipeline/product teams.
- Include links to runbooks, DB admins, and infra SRE channels.
