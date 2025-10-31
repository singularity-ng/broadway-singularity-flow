# Broadway.QuantumFlow Migration Guide

This guide provides a comprehensive, step-by-step process for migrating existing Broadway pipelines from producers like `Broadway.DummyProducer`, `Broadway.Kafka.Producer`, or others to `Broadway.QuantumFlowProducer`. The migration focuses on durability, orchestration, and resource management using QuantumFlow workflows backed by PostgreSQL.

## Prerequisites

Before starting the migration:

1. **Dependencies**:
   - Ensure your project has the required dependencies in `mix.exs`:
     ```elixir
     defp deps do
       [
         {:broadway, "~> 1.0"},
         {:QuantumFlow, "~> 0.1"},
         {:ecto_sql, "~> 3.10"},
         {:broadway_quantum_flow, "~> 0.1.0"}
       ]
     end
     ```
   - Run `mix deps.get` to install.

2. **Database Setup**:
   - PostgreSQL 12+ with Ecto configured.
   - Connection pool configured (e.g., via `pool_size: 20` in repo config).
   - Ensure your Ecto Repo is started in your application supervision tree.

3. **Queue Table Schema**:
   - Create a PostgreSQL table for your job queue. Example schema:
     ```sql
     CREATE TABLE your_pipeline_jobs (
       id BIGSERIAL PRIMARY KEY,
       data JSONB NOT NULL,
       metadata JSONB DEFAULT '{}',
       status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'completed', 'failed')),
       inserted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
       updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
       failure_reason TEXT,
       retries INTEGER DEFAULT 0
     );

     -- Indexes for performance
     CREATE INDEX idx_your_pipeline_jobs_status ON your_pipeline_jobs (status);
     CREATE INDEX idx_your_pipeline_jobs_inserted_at ON your_pipeline_jobs (inserted_at) WHERE status = 'pending';
     CREATE INDEX idx_your_pipeline_jobs_retries ON your_pipeline_jobs (retries) WHERE status = 'failed';
     ```
   - Replace `your_pipeline_jobs` with your queue name (e.g., `embedding_jobs`).

4. **Resource Hints (Optional)**:
   - If using GPU or other resources, implement `Broadway.QuantumFlowProducer.Workflow.acquire_gpu_lock/1` or similar.
   - Example using PG advisory locks:
     ```elixir
     defp acquire_gpu_lock(queue_name) do
       # Use PG advisory lock: SELECT pg_advisory_lock(hashtext(queue_name))
       query = "SELECT pg_advisory_lock(hashtext($1))"
       case Repo.query(query, [queue_name]) do
         {:ok, %Postgrex.Result{rows: [[true]]}} -> :ok
         _ -> {:error, :lock_failed}
       end
     end
     ```

5. **Backup**:
   - Backup your existing pipeline configuration and any running jobs.
   - Test in a staging environment first.

## Step-by-Step Migration

### Step 1: Identify Your Current Producer

Review your Broadway pipeline configuration (typically in a module like `YourPipeline.start_link/1`).

Example current config (using DummyProducer):
```elixir
def start_link(opts) do
  Broadway.start_link(__MODULE__,
    name: __MODULE__,
    producer: [
      module: {Broadway.DummyProducer, []},
      concurrency: 1
    ],
    processors: [
      default: [concurrency: 10]
    ]
  )
end
```

### Step 2: Update Producer Configuration

Replace the producer module with `Broadway.QuantumFlowProducer` and add required options.

Updated config:
```elixir
def start_link(opts) do
  Broadway.start_link(__MODULE__,
    name: __MODULE__,
    producer: [
      module: {Broadway.QuantumFlowProducer, [
        workflow_name: "your_pipeline_producer",  # Unique name
        queue_name: "your_pipeline_jobs",         # Your queue table
        concurrency: 10,                          # Match or adjust from current
        batch_size: 16,                           # Optimal for your workload
        quantum_flow_config: [                          # QuantumFlow settings
          timeout_ms: 300_000,                    # 5 min timeout
          retries: 3                              # Max retries
        ],
        resource_hints: [gpu: true]               # If needed
      ]},
      concurrency: 10
    ],
    processors: [
      default: [concurrency: 10]
    ]
  )
end
```

- **workflow_name**: Must be unique per pipeline instance.
- **queue_name**: Matches your DB table (without schema prefix if using default).
- **concurrency**: Start with current value; tune based on DB capacity.
- **batch_size**: Balance between throughput and memory (8-64 typical).

### Step 3: Adapt Message Handling

Ensure your `handle_message/3` function works with the new message format.

QuantumFlowProducer yields:
```elixir
%Broadway.Message{
  data: {job_id, job_data},  # Tuple: id from DB, your original data
  metadata: job_metadata,    # From DB metadata field
  acknowledger: {Broadway.QuantumFlowProducer.Workflow, job_id}
}
```

In `handle_message/3`:
```elixir
def handle_message(%Broadway.Message{data: {job_id, data}, metadata: metadata} = msg, _context, state) do
  # Process your data
  case process_data(data, metadata) do
    {:ok, result} ->
      # Ack the message
      {Broadway.Message.ack!(msg), state}
    {:error, reason} ->
      # Nack/requeue
      Broadway.Message.failed(msg, reason)
      {msg, state}
  end
end
```

- Acks automatically call `handle_update(:ack, %{id: job_id}, state)` in the workflow.
- Failures trigger `handle_update(:requeue, %{id: job_id, reason: reason}, state)`.

### Step 4: Migrate Existing Jobs (If Applicable)

If migrating from another queue system:

1. **Export Data**:
   - Query your old queue for pending/completed jobs.
   - Transform to match new schema (e.g., map status, serialize data to JSONB).

2. **Import to New Queue**:
   ```elixir
   # Example migration script
   defmodule Migration do
     def migrate_jobs do
       old_jobs = OldQueueRepo.all(pending_jobs_query())
       Enum.each(old_jobs, fn job ->
         Repo.insert_all("your_pipeline_jobs", %{
           data: Jason.encode!(job.payload),
           metadata: Jason.encode!(%{source: "old_queue"}),
           status: "pending",
           inserted_at: job.timestamp
         })
       end)
     end
   end
   ```

3. **Handle In-Flight Jobs**:
   - Pause old pipeline.
   - Drain processing (complete current batches).
   - Migrate remaining pending jobs.

### Step 5: Implement Custom Workflow Logic (If Needed)

For advanced use cases, extend `Broadway.QuantumFlowProducer.Workflow`:

```elixir
defmodule CustomWorkflow do
  use QuantumFlow.Workflow

  # Override fetch to add custom filtering
  def fetch(state) do
    # Add priority or filtering logic
    query = from(j in ^state.queue_name,
      where: j.status == "pending" and j.priority > 0,
      limit: ^state.demand
    )
    jobs = Repo.all(query)
    {:next, :batch, %{state | jobs: jobs}}
  end

  # Custom resource acquisition
  def acquire_custom_resource(queue_name) do
    # Integrate with external service
    :ok
  end
end
```

Then use in producer opts: `workflow_module: CustomWorkflow`.

### Step 6: Update Enqueuing Logic

Change how you add jobs to the pipeline:

Old (e.g., DummyProducer - no queue):
```elixir
# No explicit enqueue
```

New (QuantumFlow):
```elixir
def enqueue_job(data, metadata \\ %{}) do
  Repo.insert_all("your_pipeline_jobs", %{
    data: Jason.encode!(data),
    metadata: Jason.encode!(metadata),
    status: "pending"
  })
end
```

- Call `enqueue_job/2` from your application code (e.g., API endpoints, schedulers).

### Step 7: Configure Application Supervision

Ensure the producer starts with your pipeline:

```elixir
# In application.ex
children = [
  YourPipeline,
  # Other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Verification

### Step 8: Run Tests

1. **Unit Tests**:
   ```bash
   cd packages/broadway_quantum_flow
   mix test test/broadway/quantum_flow_producer_test.exs
   ```

2. **Integration Tests**:
   ```bash
   mix test test/broadway/quantum_flow_producer_integration_test.exs
   ```

3. **Stress Tests** (run in CI or manually):
   ```bash
   mix test test/broadway/quantum_flow_producer_stress_test.exs
   ```

4. **End-to-End Pipeline Test**:
   - Enqueue sample jobs.
   - Start pipeline.
   - Verify jobs transition: pending → in_progress → completed.
   - Check logs for errors.

### Step 9: Monitor Migration

- **Queue Health**:
  ```sql
  SELECT status, COUNT(*), AVG(EXTRACT(EPOCH FROM (updated_at - inserted_at))) as avg_duration
  FROM your_pipeline_jobs GROUP BY status;
  ```

- **Logs**: Watch for workflow timeouts, resource lock failures.
- **Metrics**: Track throughput, latency, error rates.

### Step 10: Rollback Plan

If issues arise:
1. Revert producer config to old module.
2. Drain new queue (process remaining jobs).
3. Migrate back any completed jobs if needed.
4. Test old pipeline.

## Common Pitfalls & Tips

- **Schema Mismatch**: Ensure `data` is JSONB; serialize complex Elixir structures.
- **Idempotency**: Make `handle_message/3` idempotent to handle retries.
- **Connection Pooling**: Monitor DB connections; adjust `pool_size` for high concurrency.
- **Timeouts**: Set `timeout_ms` based on longest expected job (e.g., 10min for ML training).
- **Testing Resources**: Mock resource acquisition in tests to avoid real locks.
- **Multi-Node**: Use unique `workflow_name` per node (e.g., append node ID).

## Post-Migration

- Update documentation with new queue management procedures.
- Set up alerting for queue backlog (>1000 pending jobs).
- Schedule regular queue cleanup (e.g., archive completed jobs after 30 days).
- Consider adding dead-letter queue for persistent failures.

For questions, refer to [ARCHITECTURE.md](ARCHITECTURE.md) or the [README.md](../README.md).