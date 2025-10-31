# Broadway.QuantumFlow

Broadway-compatible producer adapter backed by [QuantumFlow](https://hex.pm/packages/QuantumFlow) workflows for durable message production and orchestration in PostgreSQL.

This package provides a reliable producer for Broadway pipelines, using QuantumFlow to manage message fetching, batching, and state updates (ack/nack) with built-in retries and resource hints (e.g., GPU locks).

## Features

- **Durability**: Messages are fetched and tracked via QuantumFlow workflows for fault-tolerant production.
- **Batching**: Automatic grouping of messages up to configurable batch_size for efficient processing.
- **Resource Hints**: Support for acquiring resources like GPU locks during fetch.
- **Retries**: Configurable retry logic for failed workflows.
- **Integration**: Seamless drop-in replacement for Broadway producers like DummyProducer.

## Installation

Add `:broadway_quantum_flow` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:broadway, "~> 1.0"},
    {:QuantumFlow, "~> 0.1"},
    {:ecto_sql, "~> 3.10"},
    {:broadway_quantum_flow, path: "../packages/broadway_quantum_flow"}  # For local development
  ]
end
```

Then run:

```bash
$ mix deps.get
```

## API

### Broadway.QuantumFlowProducer.start_link/1

Starts the producer GenServer with an attached QuantumFlow workflow.

**Options**:
- `workflow_name`: (required) Unique name for the QuantumFlow workflow.
- `queue_name`: (required) PostgreSQL table name for the job queue.
- `concurrency`: (optional, default 10) Number of concurrent producers.
- `batch_size`: (optional, default 16) Maximum batch size for yielding.
- `quantum_flow_config`: (optional) QuantumFlow-specific config (e.g., `[timeout_ms: 300_000, retries: 3]`).
- `resource_hints`: (optional) Hints like `[gpu: true]` for resource acquisition.

**Example**:
```elixir
{:ok, _pid} = Broadway.QuantumFlowProducer.start_link([
  workflow_name: "embedding_producer",
  queue_name: "embedding_jobs",
  concurrency: 10,
  batch_size: 16,
  resource_hints: [gpu: true]
])
```

### Workflow Steps

The integrated workflow (`Broadway.QuantumFlowProducer.Workflow`) handles:
- `fetch/1`: Queries pending jobs (LIMIT demand), applies resource hints.
- `batch/1`: Groups jobs into batches ≤ batch_size.
- `yield/1`: Sends Broadway.Messages asynchronously.
- `handle_update(:ack, payload, state)`: Commits job as completed.
- `handle_update(:requeue, payload, state)`: Requeues on failure.

## Usage Example: Embedding Pipeline Migration

To migrate `Singularity.Embedding.BroadwayEmbeddingPipeline` from `Broadway.DummyProducer` to `Broadway.QuantumFlowProducer`:

1. **Update Broadway Config** (in `start_pipeline/5`):
   ```elixir
   # Replace:
   producer: [
     module: {Broadway.DummyProducer, []},
     concurrency: 1
   ],

   # With:
   producer: [
     module: {Broadway.QuantumFlowProducer, [
       workflow_name: "embedding_producer",
       queue_name: "embedding_jobs",
       concurrency: 10,
       batch_size: 16,
       quantum_flow_config: [timeout_ms: 300_000, retries: 3],
       resource_hints: [gpu: true]
     ]},
     concurrency: 10
   ],
   ```

2. **Prepare Queue**: Ensure `embedding_jobs` table exists with columns: `id`, `data`, `metadata`, `status` (pending/in_progress/completed/failed), `inserted_at`, `updated_at`.

3. **Enqueue Jobs**: Before running the pipeline, insert pending jobs:
   ```elixir
   # Example insertion
   Repo.insert_all("embedding_jobs", [
     %{data: artifact_data, metadata: %{}, status: "pending"}
   ])
   ```

4. **Run Pipeline**: The producer will fetch, batch, and yield artifacts for embedding processing.

## Migration Examples for Other Pipelines

### Complexity Training Pipeline Migration

For migrating `CentralCloud.ComplexityTrainingPipeline`:

```elixir
# In pipeline configuration
producer: [
  module: {Broadway.QuantumFlowProducer, [
    workflow_name: "complexity_training_producer",
    queue_name: "complexity_training_jobs",
    concurrency: 5,
    batch_size: 8,
    quantum_flow_config: [timeout_ms: 600_000, retries: 5],
    resource_hints: [gpu: true, cpu_cores: 8]
  ]},
  concurrency: 5
]
```

**Queue Schema**:
```sql
CREATE TABLE complexity_training_jobs (
  id SERIAL PRIMARY KEY,
  data JSONB,
  metadata JSONB DEFAULT '{}',
  status VARCHAR(20) DEFAULT 'pending',
  inserted_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  failure_reason TEXT
);
```

### Architecture Learning Pipeline Migration

For `Singularity.ArchitectureLearningPipeline`:

```elixir
producer: [
  module: {Broadway.QuantumFlowProducer, [
    workflow_name: "architecture_learning_producer",
    queue_name: "architecture_learning_jobs",
    concurrency: 3,
    batch_size: 4,
    quantum_flow_config: [timeout_ms: 900_000, retries: 3],
    resource_hints: [gpu: false, memory_gb: 16]
  ]},
  concurrency: 3
]
```

## Configuration

Defaults are set in `config/config.exs`:

```elixir
config :QuantumFlow,
  timeout_ms: 300_000,  # 5-minute workflow timeout
  retries: 3            # Max retries on failure
```

Override in your app's config:
```elixir
config :QuantumFlow,
  timeout_ms: 600_000,
  retries: 5
```

For GPU hints, ensure resource acquisition logic in `Broadway.QuantumFlowProducer.Workflow.acquire_gpu_lock/1` is implemented (e.g., PG advisory locks).

## Troubleshooting

### Common Issues

**Producer fails to start with "workflow failed" error**:
- Check QuantumFlow dependency is properly installed and configured.
- Verify database connection and permissions.
- Ensure workflow_name is unique across the system.

**Messages not being yielded**:
- Confirm queue table exists with correct schema.
- Check for pending jobs in the queue: `SELECT COUNT(*) FROM queue_name WHERE status = 'pending'`
- Verify QuantumFlow workflow is running: check logs for workflow initialization.

**High latency or low throughput**:
- Increase `concurrency` setting (start with 2x CPU cores).
- Adjust `batch_size` (larger batches reduce overhead but increase memory usage).
- Monitor database performance and add indexes on `status` and `inserted_at` columns.

**Resource hint failures**:
- Implement `acquire_gpu_lock/1` function with proper locking mechanism.
- Check resource availability before starting pipelines.
- Add timeout handling for resource acquisition.

**Database connection errors**:
- Ensure Ecto repo is properly configured and connected.
- Check connection pool size in database config.
- Monitor for connection leaks in application logs.

### Debugging Commands

```bash
# Check queue status
SELECT status, COUNT(*) FROM embedding_jobs GROUP BY status;

# Monitor workflow state
# (QuantumFlow provides workflow inspection tools)

# Check Broadway producer state
:sys.get_state(Broadway.QuantumFlowProducer)
```

### Performance Tuning

- **Concurrency**: Start with 1-2 per CPU core, increase gradually.
- **Batch Size**: 16-64 messages per batch for most workloads.
- **Timeouts**: 5-15 minutes for long-running ML tasks.
- **Resource Hints**: Use only when necessary to avoid contention.

## Production Deployment

For production deployments use the checklist and reference docs/DEPLOYMENT.md for full operational guidance.

### Production checklist (minimum)
- [ ] Database migrations applied for all queue tables and indexes
- [ ] QuantumFlow configured with production timeouts and retries
- [ ] Resource acquisition logic (GPU/locks) implemented and tested
- [ ] Monitoring and alerting configured for queue depth, error rate, and latency
- [ ] Backup strategy and restore runbook documented
- [ ] Rollout and rollback procedures documented and rehearsed

### Environment variables (recommended)
The following are typical env vars used by this package and the runtime system:

```bash
# Database (Ecto)
export DATABASE_URL="ecto://user:pass@host:5432/db"
export POOL_SIZE=20

# QuantumFlow / workflow tuning
export PGFLOW_TIMEOUT_MS=300000    # workflow timeout in ms
export PGFLOW_RETRIES=3            # workflow retry attempts

# Broadway
export BROADWAY_CONCURRENCY=10
export BROADWAY_BATCH_SIZE=16

# Resource hints and discovery
export GPU_LOCK_TABLE="resource_locks"  # if using DB advisory locks / table
```

Place environment-specific values in your secrets manager or Nix configuration and avoid committing credentials.

### Queue schema & database setup
Ensure each queue table is created and indexed. Example minimal migration:

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

CREATE INDEX IF NOT EXISTS idx_embedding_jobs_status_inserted_at ON embedding_jobs (status, inserted_at);
```

Run DB migrations before starting pipelines and verify indexes to avoid table scans on high load.

### Monitoring & observability
Expose and collect the following:
- Queue depth: e.g. `SELECT COUNT(*) FROM <queue> WHERE status = 'pending'`
- Processing throughput: completed jobs / minute
- Error rate: failed jobs / total jobs
- End-to-end latency: time from inserted_at → completed
- QuantumFlow workflow health: running workflows, failures, restarts

Recommended integrations:
- Prometheus metrics for Broadway and QuantumFlow (or instrument counters in your app)
- Dashboards for queue depth and latency
- Alerts:
  - Queue depth > X for Y minutes
  - Error rate > Z%
  - Workflow restart / crash rate spike

### Scaling recommendations
- Horizontal scale: run multiple pipeline instances sharing the same queue. Tune concurrency per instance based on CPU and DB capacity.
- Batch sizing: increase batch_size to improve efficiency; monitor memory usage per worker.
- DB scaling:
  - Use connection pooling with adequate pool size.
  - For heavy fetch workloads consider read replicas for non-mutating reads, but writes (ack/requeue) must go to primary.
- Resource hints:
  - Use only when necessary. Implement robust timeouts and fallbacks for GPU/lock acquisition to prevent deadlock/starvation.

### Health checks & graceful shutdown
- Implement liveness/readiness checks that validate DB connectivity and QuantumFlow workflow registration.
- On shutdown, allow in-flight batches to finish or be requeued by QuantumFlow within configured timeouts.

### Rollout & rollback strategy
- Canary rollout: start with 1 instance at production settings and validate metrics (queue depth, latency, error rate).
- Gradually increase concurrency and instance count (e.g., 2x per CPU core) while observing metrics.
- If rollback required:
  - Pause producers (scale down) and switch to previous producer if needed (e.g., DummyProducer fallback).
  - Ensure a DB-backed snapshot or export of pending jobs exists before destructive migrations.

### GPU/resource lock guidance
- Prefer advisory locks (Postgres advisory locks or a dedicated locks table) with timeouts.
- Ensure lock acquisition has a bounded wait and proper release on failures.
- Monitor lock contention as part of operational dashboards.

### QuantumFlow-specific recommendations
- Keep workflow_name unique per logical producer to avoid collisions.
- Tune `PGFLOW_TIMEOUT_MS` and `PGFLOW_RETRIES` for expected job runtimes.
- Use QuantumFlow workflow inspection tools in staging to validate lifecycle behavior.

### Nix and reproducible builds
This project uses Nix for reproducible development/build environments. Use the project's Nix shells and CI images when running benchmarks or integration tests to match production dependencies.

For full production configuration, troubleshooting steps and rollback procedures see `docs/DEPLOYMENT.md`.
## Testing

Run unit and integration tests:

```bash
$ cd packages/broadway_quantum_flow
$ mix test
```

Tests use Mox for mocking QuantumFlow and database interactions.

## License

MIT License. See [LICENSE](LICENSE) (add if needed).