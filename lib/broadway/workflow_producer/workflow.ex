defmodule Broadway.WorkflowProducer.Workflow do
  @moduledoc """
  Workflow implementation for Broadway.WorkflowProducer.

  Integrates with Singularity.Workflow system to provide durable message production
  with batching, retries, and resource hints like GPU locks.
  """

  alias Broadway.Message
  alias Singularity.Workflow.Notifications

  @doc """
  Define the workflow steps for message processing.
  """
  def __workflow_steps__ do
    [
      {:fetch_messages, &__MODULE__.fetch_messages/1, depends_on: []},
      {:adjust_batch, &__MODULE__.adjust_batch/1, depends_on: [:fetch_messages]},
      {:yield_and_commit, &__MODULE__.yield_and_commit/1, depends_on: [:adjust_batch]}
    ]
  end

  @doc """
  Fetch messages step: Query the queue for pending jobs, limited by demand.
  """
  def fetch_messages(state) do
    %{demand: demand, batch_size: _batch_size, queue_name: queue_name, resource_hints: _hints} = state

    # Use workflow wrapper to read messages (hides PGMQ implementation)
    repo = get_repo()
    
    case Notifications.receive_message(queue_name, repo, limit: demand, visibility_timeout: 30) do
      {:ok, messages} ->
        # Convert workflow messages to our internal format
        jobs = Enum.map(messages, fn msg ->
          %{id: msg.message_id, data: msg.payload, metadata: %{}}
        end)

        {:ok, Map.put(state, :jobs, jobs)}

      {:error, reason} ->
        {:error, "Failed to read from workflow queue #{queue_name}: #{inspect(reason)}"}
    end
  end

  defp get_repo do
    Application.get_env(:broadway_singularity_flow, :repo, BroadwaySingularityFlow.Repo)
  end

  @doc """
  Adjust batch decision step.
  """
  def adjust_batch(state) do
    # For now, just pass through - batching logic can be added here
    {:ok, state}
  end

  @doc """
  Yield messages and commit step.
  """
  def yield_and_commit(state) do
    %{jobs: jobs} = state

    # Convert jobs to Broadway messages
    messages = Enum.map(jobs, fn job ->
      %Message{
        data: {job.id, job.data},
        metadata: job.metadata || %{},
        acknowledger: {Broadway.WorkflowProducer, self(), job.id}
      }
    end)

    # Return messages as part of workflow result
    {:ok, Map.put(state, :messages, messages)}
  end
end
