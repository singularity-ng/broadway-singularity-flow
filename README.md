# Broadway.SingularityWorkflowsProducer

Broadway producer adapter backed by Singularity Workflow orchestration for durable,
PostgreSQL-backed message production. The producer coordinates with
`SingularityWorkflow` to fetch work items, apply batching, manage resource hints
(GPU locks, CPU cores, etc.), and ack/requeue jobs transactionally.

## Features

- **Durability** – workflow state is persisted in PostgreSQL for crash recovery.
- **Batching** – demand-aware batching with queue depth and latency heuristics.
- **Resource Hints** – optional GPU/CPU lock acquisition tied to workflow steps.
- **Retry Semantics** – configurable retries and stateful requeue handling.
- **Observability** – workflow metadata and telemetry hooks for monitoring.

## Installation

Add `:broadway_singularity_flow` and its sibling workflow library to your
`mix.exs` dependencies:

```elixir
def deps do
  [
    {:broadway, "~> 1.0"},
    {:singularity_workflow, path: "../singularity-workflows"},
    {:ecto_sql, "~> 3.10"},
    {:broadway_singularity_flow, path: "../packages/broadway_singularity_flow"}
  ]
end
```

Fetch dependencies with:

```bash
mix deps.get
```

## API

### `Broadway.SingularityWorkflowsProducer.start_link/1`

Starts the producer GenServer and spins up the coupled `SingularityWorkflow`
process.

Required options:

- `:workflow_name` – unique identifier for the workflow instance
- `:queue_name` – PostgreSQL table (or schema-qualified name) backing the queue

Optional options:

- `:concurrency` – number of producer stages (default: `10`)
- `:batch_size` – max messages per yield (default: `16`)
- `:singularity_workflows_config` – workflow runtime config (timeouts, retries)
- `:resource_hints` – list/map describing required external resources

```elixir
{:ok, _pid} =
  Broadway.SingularityWorkflowsProducer.start_link(
    workflow_name: "embedding_producer",
    queue_name: "embedding_jobs",
    concurrency: 10,
    batch_size: 16,
    singularity_workflows_config: [timeout_ms: 300_000, retries: 3],
    resource_hints: [gpu: true]
  )
```

### Workflow Steps

`Broadway.SingularityWorkflowsProducer.Workflow` implements the step pipeline:

- `fetch/1` – pulls pending rows constrained by demand
- `adjust_batch/1` – tunes batch size using queue depth and ack latency
- `batch/1` – transforms rows into `Broadway.Message` batches
- `yield_and_commit/1` – reserves resources, marks jobs `in_progress`, yields
- `handle_update/3` – processes `:ack` / `:requeue` updates and releases hints

## Example: Embedding Pipeline Migration

Update the Broadway producer configuration:

```elixir
producer: [
  module:
    {Broadway.SingularityWorkflowsProducer,
     [
       workflow_name: "embedding_producer",
       queue_name: "embedding_jobs",
       concurrency: 10,
       batch_size: 16,
       singularity_workflows_config: [timeout_ms: 300_000, retries: 3],
       resource_hints: [gpu: true]
     ]},
  concurrency: 10
]
```

Ensure the backing table has the expected columns:

```sql
CREATE TABLE embedding_jobs (
  id SERIAL PRIMARY KEY,
  data JSONB NOT NULL,
  metadata JSONB DEFAULT '{}',
  status VARCHAR(20) DEFAULT 'pending',
  inserted_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  failure_reason TEXT
);
```

## Configuration

Default runtime configuration lives in `config/config.exs`:

```elixir
config :singularity_workflows,
  timeout_ms: 300_000,
  retries: 3
```

Override in your host application as needed:

```elixir
config :singularity_workflows,
  timeout_ms: 600_000,
  retries: 5
```

For GPU/resource hints, implement the appropriate advisory locking logic inside
`Broadway.SingularityWorkflowsProducer.Workflow`.

## Troubleshooting

- **Producer fails to start** – verify the workflow repo config and database
  connectivity; ensure `workflow_name` is unique.
- **No messages delivered** – confirm pending rows exist and the queue table is
  correctly named; check workflow logs for fetch errors.
- **High latency / low throughput** – increase `:concurrency` or `:batch_size`,
  and monitor database indexes on `status` and `inserted_at`.
- **Resource hint contention** – review `acquire_hint` / `release_hint`
  implementations and confirm worker nodes are releasing locks on ack/requeue.
