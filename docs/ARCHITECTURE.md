# Broadway.QuantumFlow Architecture

## Overview

The Broadway.QuantumFlow adapter integrates Broadway's message processing pipeline with QuantumFlow's workflow orchestration, using PostgreSQL as the durable backing store. This architecture provides fault-tolerant, distributed message production with built-in state management, retries, and resource coordination.

Key components:
- **Broadway.QuantumFlowProducer**: GenServer-based producer that handles demand and yields messages.
- **QuantumFlow Workflow**: Orchestrates the fetch-batch-yield cycle with durable state in PostgreSQL.
- **Queue Table**: PostgreSQL table storing job state (pending, in_progress, completed, failed).
- **Resource Manager**: Optional integration for acquiring resources like GPUs during fetch.

## Architecture Diagram

```mermaid
graph TD
    A[Broadway Pipeline] --> B[Broadway.QuantumFlowProducer]
    B --> C[handle_demand]
    C --> D[QuantumFlow Workflow Enqueue: fetch]
    D --> E[PostgreSQL Queue Query<br/>LIMIT demand, status='pending']
    E --> F[Acquire Resource Hints<br/>(e.g., GPU Lock)]
    F --> G[Batch Jobs<br/>chunk_every(batch_size)]
    G --> H[Yield Messages<br/>send {:workflow_yield, messages}]
    H --> I[Broadway Processing<br/>(handle_message)]
    I --> J[Ack/Nack<br/>handle_update(:ack/:requeue)]
    J --> K[Update Job Status<br/>completed/failed]
    K --> L[Workflow State Update<br/>QuantumFlow durable storage]
    L --> M[Retry Logic<br/>if max_retries exceeded]
    
    subgraph "PostgreSQL"
        E
        K
        L
    end
    
    subgraph "Resource Layer"
        F
    end
```

### Component Interactions

1. **Demand Handling**: Broadway demands messages, triggering QuantumFlow workflow enqueue.
2. **Fetch Phase**: Query pending jobs, apply resource hints (e.g., advisory locks for GPUs).
3. **Batching**: Group jobs into configurable batches to optimize processing.
4. **Yielding**: Asynchronously send Broadway.Messages to the pipeline.
5. **Processing & Ack**: Pipeline processes messages; acks/nacks update job status via workflow.
6. **State Management**: All state (progress, failures, retries) persisted in PostgreSQL for durability.

## Workflow Mapping

### Core Workflow Steps (Broadway.QuantumFlowProducer.Workflow)

- **fetch(state)**: 
  - Input: `%{demand: n, batch_size: m, queue_name: table, resource_hints: hints}`
  - Actions: Acquire resources, query `SELECT id, data, metadata FROM queue_name WHERE status='pending' ORDER BY inserted_at LIMIT n`
  - Output: `{:next, :batch, %{jobs: fetched_jobs}}`
  - Error Handling: Retry on DB errors, log resource acquisition failures.

- **batch(state)**:
  - Input: `%{jobs: list, batch_size: m}`
  - Actions: `Enum.chunk_every(jobs, batch_size)` → Create Broadway.Messages with acknowledgers.
  - Output: `{:next, :yield, %{batches: message_batches}}` or `{:halt, :no_jobs}` if empty.
  - Error Handling: Graceful halt on empty queues.

- **yield(state)**:
  - Input: `%{batches: list, workflow_pid: pid}`
  - Actions: `send(producer_pid, {:workflow_yield, messages})`, update jobs to 'in_progress'.
  - Output: `{:next, :wait_acks, %{yielded_at: now()}}`
  - Error Handling: Async yield; failures handled in Broadway failure callbacks.

- **wait_acks(state)**:
  - Passive step; awaits ack/nack updates.
  - Output: `{:halt, :waiting}`

### Update Handlers

- **handle_update(:ack, %{id: job_id}, state)**:
  - Update job status to 'completed'.
  - Log success.

- **handle_update(:requeue, %{id: job_id, reason: error}, state)**:
  - Update status to 'failed', increment retries.
  - If retries < max, requeue; else, dead-letter.

## Trade-offs

### Advantages

- **Durability & Reliability**: PostgreSQL-backed workflows ensure no message loss on crashes/restarts. At-least-once semantics with idempotent processing.
- **Orchestration**: Built-in retry, timeout, and state management without external queues (e.g., RabbitMQ).
- **Resource Coordination**: Native support for distributed locks (PG advisory locks) for scarce resources like GPUs.
- **Scalability**: Horizontal scaling via multiple producers sharing the queue; configurable concurrency.
- **Observability**: Full audit trail in DB; easy querying for metrics (queue depth, failure rates).

### Disadvantages

- **Database Dependency**: All operations bottleneck on PostgreSQL; high-load scenarios may require DB optimization (indexes, connection pooling).
- **Latency Overhead**: Workflow orchestration adds ~10-50ms per batch vs. simple producers like DummyProducer. Suitable for ML workloads, not ultra-low-latency.
- **Complexity**: More setup than basic producers (schema, migrations, resource impl). Steeper learning curve for QuantumFlow.
- **Cost**: PG writes for every ack/nack; monitor IOPS in cloud environments.
- **Single Point of Failure**: If DB is down, production halts (mitigate with replicas, but reads/writes need primary).

### When to Use

- **Use Broadway.QuantumFlow** for: Durable ML pipelines, distributed training jobs, resource-constrained environments (GPUs), fault-tolerant systems.
- **Avoid** for: Simple in-memory processing, high-frequency trading, non-durable prototypes.

### Performance Considerations

- **Throughput**: 100-1000 msgs/sec depending on DB config and batch_size.
- **Memory**: Low; batches processed asynchronously.
- **Tuning**: Index on `(status, inserted_at)`; use `UNLOGGED` tables for high-write queues if durability trade-off acceptable.

### Alternatives Comparison

| Feature | Broadway.QuantumFlow | Broadway.Kafka | Broadway.SQS |
|---------|-----------------|----------------|--------------|
| Durability | High (PG) | High (distributed) | High (AWS) |
| Setup Complexity | Medium | High | Low |
| Resource Locks | Native | Custom | Custom |
| Cost | DB storage | Kafka cluster | Pay-per-use |
| Latency | Medium | Low-Medium | Low |
 
For more details, see [QuantumFlow Documentation](https://hex.pm/packages/QuantumFlow).

## Atomic yield and commit

To ensure produced messages and the corresponding DB state transition remain consistent, the workflow uses an Ecto.Multi-backed "yield and commit" step. The workflow:

- Builds an `Ecto.Multi` with:
  1. `:mark_in_progress` — an update_all that marks all yielded job rows as `in_progress`.
  2. `:yield_messages` — a `run` step that sends the Broadway messages to the producer.

- Executes the Multi with `Repo.transaction/1`. If the DB update fails, the `:yield_messages` step is not executed and no messages are emitted. This centralizes DB updates inside the workflow and makes ack/nack updates transactional and durable.

Failure semantics:
- If marking jobs as `in_progress` fails, messages are not sent.
- If sending messages succeeds but the transaction is rolled back later for any reason, the DB will revert; side-effects (sent messages) cannot be undone — the workflow ensures the critical DB update runs prior to sending to minimize this window.
- All ack/requeue updates are performed by the workflow using transactions so that ack/nack handling is centralized for durability.

This approach keeps all DB updates within the QuantumFlow workflow, simplifying reasoning about durability and reducing duplication of DB logic in the producer.