defmodule Broadway.SingularityWorkflowsProducer do
  @moduledoc """
  Broadway producer adapter backed by SingularityWorkflow workflows for durable message production.

  This producer integrates with SingularityWorkflow to fetch messages from a PostgreSQL queue in a durable,
  orchestrated manner, supporting batching, retries, and resource hints like GPU locks.
  """

  use GenStage

  alias Broadway.Message
  alias Singularity.Workflow.Workflow
  require Logger

  @behaviour Broadway.Producer

  def start_link(opts) do
    workflow_name = Keyword.fetch!(opts, :workflow_name)
    queue_name = Keyword.fetch!(opts, :queue_name)
    concurrency = Keyword.get(opts, :concurrency, 10)
    batch_size = Keyword.get(opts, :batch_size, 16)
    singularity_workflows_config = Keyword.get(opts, :singularity_workflows_config, [])
    resource_hints = Keyword.get(opts, :resource_hints, [])

    GenStage.start_link(__MODULE__, %{
      workflow_name: workflow_name,
      queue_name: queue_name,
      concurrency: concurrency,
      batch_size: batch_size,
      singularity_workflows_config: singularity_workflows_config,
      resource_hints: resource_hints
    }, name: via_tuple(workflow_name))
  end

  @impl true
  def init(state) do
    # Start SingularityWorkflow workflow child
    {:ok, workflow_pid} = Workflow.start_link(state.workflow_name, __MODULE__.Workflow, state)

    {:producer, %{state | workflow_pid: workflow_pid}}
  end

  @impl true
  def handle_demand(demand, %{workflow_pid: workflow_pid} = state) when demand > 0 do
    # Calculate a light-weight queue depth and recent ack latency to inform
    # dynamic batching decisions inside the workflow. These helpers are
    # intentionally non-blocking and fall back to safe defaults on error.
    queue_depth = get_queue_depth(state.queue_name)
    recent_ack_latency = measure_recent_ack_latency()
 
    # Enqueue SingularityWorkflow workflow to fetch up to demand messages and include
    # metrics for the workflow to adjust batching dynamically.
    Workflow.enqueue(workflow_pid, :fetch, %{
      demand: demand,
      batch_size: state.batch_size,
      queue_name: state.queue_name,
      resource_hints: state.resource_hints,
      queue_depth: queue_depth,
      recent_ack_latency: recent_ack_latency
    })
 
    # Async yield will happen via send_messages/1
    {:noreply, [], state}
  end

  def handle_demand(_demand, state), do: {:noreply, [], state}

  # Compatibility for tests invoking the 3-arity variant
  def handle_demand(demand, _from, state), do: handle_demand(demand, state)

  def handle_failure({:basic, reason}, [{_pid, batch}], _context, state) do
    # On failure, update SingularityWorkflow to requeue the batch
    Enum.each(batch, fn %Message{data: {id, _data}} = msg ->
      Workflow.update(state.workflow_pid, :requeue, %{id: id, reason: reason})
      Message.failed(msg, reason)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:workflow_yield, messages}, state) do
    {:noreply, messages, state}
  end

  @doc """
  Handle external ack notifications by informing the SingularityWorkflow workflow.

  Some integration tests and external components may send `{:ack, job_id}` or
  `{:requeue, job_id, reason}` messages to the producer. Forward these to the
  workflow so that the workflow's `handle_update/3` callbacks perform the
  database updates transactionally.
  """
  def handle_info({:ack, job_id}, %{workflow_pid: workflow_pid} = state) do
    Workflow.update(workflow_pid, :ack, %{id: job_id})
    {:noreply, [], state}
  end

  def handle_info({:requeue, job_id, reason}, %{workflow_pid: workflow_pid} = state) do
    Workflow.update(workflow_pid, :requeue, %{id: job_id, reason: reason})
    {:noreply, [], state}
  end

  # Helpers for dynamic batching decisions
 
  @doc false
  defp get_queue_depth(queue_name) when is_binary(queue_name) or is_atom(queue_name) do
    # Lightweight COUNT(*) query. Keep it simple and fast.
    try do
      import Ecto.Query
      # Use dynamic fragment to count rows for the configured queue table.
      # The query is intentionally minimal: SELECT COUNT(*) FROM queue LIMIT 1 scan.
      query = from(q in queue_name, where: q.status == "pending", select: count(q.id))
      case repo().one(query) do
        count when is_integer(count) and count >= 0 -> count
        _ -> 0
      end
    rescue
      _ -> 0
    end
  end
 
  defp get_queue_depth(_), do: 0
 
  @doc false
  defp measure_recent_ack_latency() do
    # Allow injection of a telemetry module via application config for testing.
    telemetry_mod = Application.get_env(:broadway_singularity_flow, :telemetry_module, Singularity.Telemetry)
 
    if is_atom(telemetry_mod) and function_exported?(telemetry_mod, :get_recent_ack_latency, 0) do
      try do
        telemetry_mod.get_recent_ack_latency()
      rescue
        _ -> 0
      end
    else
      # Telemetry not available or no handler — return safe default.
      0
    end
  end
 
  defp repo do
    Application.get_env(:broadway_singularity_flow, :repo, Singularity.Repo)
  end

  defp via_tuple(workflow_name), do: {:via, Registry, {Broadway.SingularityWorkflowsProducer.Registry, workflow_name}}

  @impl Broadway.Producer
  def prepare_for_start(module, opts), do: {module, opts}

  @impl Broadway.Producer
  def prepare_for_draining(state), do: {:noreply, [], state}
end
