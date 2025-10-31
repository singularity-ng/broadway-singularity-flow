defmodule Broadway.QuantumFlow do
  @version "0.1.0"

  @moduledoc """
  Broadway.QuantumFlow is a Broadway-compatible producer adapter backed by QuantumFlow workflows.
 
  Overview
 
  Provides durable, orchestrated message production using PostgreSQL-backed QuantumFlow workflows.
  Designed for pipelines that require strong durability, retry semantics, and optional resource hints
  (e.g., GPU locks).
 
  Benefits
 
  - Durability: persistent workflow state in PostgreSQL for crash recovery.
  - Orchestration: fetch → batch → yield workflow with retries and timeouts.
  - Resource hints: acquire external resources (GPU) during fetch to avoid contention.
  - Observability: workflow state stored in DB for monitoring and debugging.
 
  Quick usage
 
  ```elixir
  {:ok, _pid} = Broadway.QuantumFlowProducer.start_link(
    workflow_name: "my_pipeline",
    queue_name: "my_jobs",
    concurrency: 10,
    batch_size: 16,
    quantum_flow_config: [timeout_ms: 300_000, retries: 3],
    resource_hints: [gpu: true]
  )
  ```
 
  Configuration
 
  Configure QuantumFlow and repo in your application config; see README for details.
 
  Version
 
  #{@version}
  """

  def version, do: @version
end