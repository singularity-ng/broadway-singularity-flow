defmodule Broadway.SingularityWorkflowsProducer.Workflow do
  @moduledoc """
  SingularityWorkflow workflow implementation for Broadway.SingularityWorkflowsProducer.

  Defines steps for fetching, batching, and yielding messages from a PostgreSQL queue,
  with support for ack/nack updates and stateful resource hint caching (e.g. GPU locks).
  """

  use Singularity.Workflow.Workflow

  alias Broadway.Message
  require Logger

  @doc false
  # Ensure the state includes resource_hints and yielded_job_hints maps
  def init_state(state) when is_map(state) do
    state
    |> Map.put_new(:resource_hints, %{})
    |> Map.put_new(:yielded_job_hints, %{})
  end

  # Workflow steps

  @doc """
  Fetch step: Query the queue for pending jobs, limited by demand.
  """
  def fetch(state) do
    state = init_state(state)

    %{demand: demand, batch_size: _batch_size, queue_name: queue_name, resource_hints: _hints} = state

    import Ecto.Query

    query =
      from(j in queue_name,
        where: j.status == "pending",
        order_by: [asc: j.inserted_at],
        limit: ^demand,
        select: %{id: j.id, data: j.data, metadata: j.metadata}
      )

    jobs = repo().all(query)

    next_state = %{state | jobs: jobs, fetched_at: DateTime.utc_now()}

    {:next, :adjust_batch, next_state}
  end

  @doc """
  Adjust batch decision step.
  """
  def adjust_batch(%{jobs: _jobs, batch_size: batch_size, queue_depth: queue_depth, recent_ack_latency: recent_ack_latency} = state) do
    effective_batch_size =
      cond do
        (is_integer(queue_depth) and queue_depth > 5000) or (is_integer(recent_ack_latency) and recent_ack_latency > 200) ->
          max(4, div(batch_size, 2))

        (is_integer(queue_depth) and queue_depth < 1000) and (is_integer(recent_ack_latency) and recent_ack_latency < 50) ->
          min(batch_size * 2, 512)

        true ->
          batch_size
      end

    {:next, :batch, Map.put(state, :effective_batch_size, effective_batch_size)}
  end

  @doc """
  Batch step: Group fetched jobs into Broadway.Messages.
  """
  def batch(%{jobs: jobs, batch_size: batch_size} = state) when length(jobs) > 0 do
    effective_batch_size = Map.get(state, :effective_batch_size, batch_size)

    batches =
      jobs
      |> Enum.chunk_every(effective_batch_size)
      |> Enum.map(fn batch ->
        batch
        |> Enum.map(fn job ->
          %Message{
            data: {job.id, job.data},
            metadata: job.metadata,
            acknowledger: {__MODULE__, job.id}
          }
        end)
      end)

    next_state = %{state | batches: batches}
    {:next, :yield_and_commit, next_state}
  end

  def batch(state), do: {:halt, :no_jobs, state}

  @doc """
  Yield-and-commit step:
  - Build a transaction that attempts to reserve resources (single-step update_all per resource_key)
    and mark selected job rows as `in_progress`. Only when the DB work succeeds do we send messages.
  - After success, cache hint tokens in the workflow state so they can be released on ack/requeue.
  """
  def yield_and_commit(%{batches: batches, workflow_pid: workflow_pid} = state) do
    state = init_state(state)
    producer_pid = Singularity.Workflow.Workflow.get_parent(workflow_pid)

    # Flatten messages and attach workflow_pid into metadata
    messages =
      batches
      |> Enum.flat_map(fn batch ->
        Enum.map(batch, fn msg ->
          metadata = Map.put(msg.metadata || %{}, :workflow_pid, workflow_pid)
          %{msg | metadata: metadata}
        end)
      end)

    # Map job ids and resource requirements from state.jobs
    jobs = Map.get(state, :jobs, [])
    ids = Enum.map(jobs, & &1.id)

    # Determine distinct resource keys required for this batch
    resource_keys =
      jobs
      |> Enum.map(fn j -> Map.get(j.metadata || %{}, :resource_key) end)
      |> Enum.uniq()
      |> Enum.filter(& &1)

    multi = Ecto.Multi.new()

    # For each distinct resource_key, use acquire_hint to get reservation
    # This demonstrates the helper function usage
    multi =
      Enum.reduce(resource_keys, multi, fn resource_key, m ->
        key_str = to_string(resource_key)
        step = String.to_atom("reserve_#{String.replace(key_str, ~r/[^A-Za-z0-9_]/, "_")}")

        m
        |> Ecto.Multi.run(step, fn repo, _changes ->
          # Use acquire_hint logic within transaction
          case acquire_hint_in_transaction(repo, state, resource_key) do
            {:ok, token} -> {:ok, token}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)

    # Mark jobs in_progress (only those ids)
    multi =
      Ecto.Multi.run(multi, :mark_in_progress, fn repo, _changes ->
        mark_jobs_in_progress(repo, state, ids)
      end)

    # Yield messages as side-effect
    multi =
      Ecto.Multi.run(multi, :yield_messages, fn _repo, _changes ->
        Enum.chunk_every(messages, 50)
        |> Enum.each(fn batch_msgs ->
          send(producer_pid, {:workflow_yield, batch_msgs})
        end)

        {:ok, :ok}
      end)

    case repo().transaction(multi) do
      {:ok, changes} ->
        # Extract reservation tokens from changes and cache in state.resource_hints
        reservation_changes =
          changes
          |> Enum.filter(fn {k, _v} -> Atom.to_string(k) |> String.starts_with?("reserve_") end)

        resource_hints =
          Enum.reduce(reservation_changes, Map.get(state, :resource_hints, %{}), fn {step_key, token}, acc ->
            # derive resource_key back from step_key
            step_name = Atom.to_string(step_key)
            ["reserve", resource_part] = String.split(step_name, "_", parts: 2)
            resource_key = resource_part
            Map.put(acc, resource_key, %{holder: inspect(workflow_pid), token: token, locked_at: DateTime.utc_now()})
          end)

        # Build mapping of job_id -> {resource_key, token} for yielded jobs that requested resources
        yielded_job_hints =
          Enum.reduce(jobs, Map.get(state, :yielded_job_hints, %{}), fn job, acc ->
            case Map.get(job.metadata || %{}, :resource_key) do
              nil -> acc
              rk ->
                key = to_string(rk)
                case Map.get(resource_hints, key) do
                  %{token: token} -> Map.put(acc, job.id, {key, token})
                  _ -> acc
                end
            end
          end)

        new_state =
          state
          |> Map.put(:resource_hints, resource_hints)
          |> Map.put(:yielded_job_hints, yielded_job_hints)
          |> Map.put(:yielded_at, DateTime.utc_now())

        {:next, :wait_acks, new_state}

      {:error, failed_op, reason, _changes_so_far} ->
        Logger.error("yield_and_commit failed (#{failed_op}): #{inspect(reason)}")
        # No messages were sent if reservation or mark failed (transaction rolled back)
        {:halt, {:error, reason}, state}
    end
  end

  @doc """
  Wait for acks: passive step.
  """
  def wait_acks(state), do: {:halt, :waiting, state}

  # Update handlers for ack/nack that release hints as required

  @doc """
  Handle ack: release any held resource hint for this job and mark completed.
  """
  def handle_update(:ack, %{id: job_id}, state) do
    state = init_state(state)

    repo = repo()

    case Map.get(state.yielded_job_hints, job_id) do
      nil ->
        # No resource held for this job; just mark completed
        case update_job_status(repo, state, [job_id], "completed") do
          {:ok, _} -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end

      {resource_key, token} ->
        # Release resource and mark job completed in a single transaction
        import Ecto.Query

        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:release_resource, fn repo, _ ->
            # Use release_hint logic within transaction
            case release_hint_in_transaction(repo, state, resource_key, token) do
              {:ok, _} -> {:ok, :released}
              {:error, reason} -> {:error, reason}
            end
          end)
          |> Ecto.Multi.run(:mark_completed, fn repo, _ ->
            update_job_status(repo, state, [job_id], "completed")
          end)

        case repo().transaction(multi) do
          {:ok, _changes} ->
            new_resource_hints = Map.delete(state.resource_hints, resource_key)
            new_yielded = Map.delete(state.yielded_job_hints, job_id)
            {:ok, %{state | resource_hints: new_resource_hints, yielded_job_hints: new_yielded}}

          {:error, failed_op, reason, _} ->
            Logger.error("ack release failed (#{failed_op}): #{inspect(reason)}")
            {:error, reason, state}
        end
    end
  end

  # Handle requeue: release resource hint and mark job failed/requeued.
  # Current behavior: always release hint on requeue to avoid stale holds.
  def handle_update(:requeue, %{id: job_id, reason: reason}, state) do
    state = init_state(state)

    repo = repo()

    case Map.get(state.yielded_job_hints, job_id) do
      nil ->
        case update_job_status(repo, state, [job_id], "failed", reason) do
          {:ok, _} ->
            {:ok, %{state | retries: Map.get(state, :retries, 0) + 1}}

          {:error, err} ->
            {:error, err, state}
        end

      {resource_key, token} ->
        # Release resource and mark job failed in a single transaction
        import Ecto.Query

        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:release_resource, fn repo, _ ->
            # Use release_hint logic within transaction
            case release_hint_in_transaction(repo, state, resource_key, token) do
              {:ok, _} -> {:ok, :released}
              {:error, reason} -> {:error, reason}
            end
          end)
          |> Ecto.Multi.run(:mark_failed, fn repo, _ ->
            update_job_status(repo, state, [job_id], "failed", reason)
          end)

        case repo().transaction(multi) do
          {:ok, _changes} ->
            new_resource_hints = Map.delete(state.resource_hints, resource_key)
            new_yielded = Map.delete(state.yielded_job_hints, job_id)
            {:ok, %{state | resource_hints: new_resource_hints, yielded_job_hints: new_yielded, retries: Map.get(state, :retries, 0) + 1}}

          {:error, failed_op, reason, _} ->
            Logger.error("requeue release failed (#{failed_op}): #{inspect(reason)}")
            {:error, reason, state}
        end
    end
  end

  # Public (private to module) helpers for reservation semantics.
  # Note: these helpers are intentionally simple and deterministic.

  @doc """
  Acquire a resource hint for external resource management.
  
  This is the public API for acquiring resource hints outside of workflow transactions.
  Use this when you need to manage resources independently of workflow execution.
  
  ## Examples
  
      {:ok, token, new_state} = acquire_hint(state, "gpu", [])
      {:error, :not_available, state} = acquire_hint(state, "busy_resource", [])
  """
  def acquire_hint(state, resource_key, _opts \\ []) do
    state = init_state(state)
    key_str = to_string(resource_key)
    current_holder = inspect(state.workflow_pid || self())

    # If already held by this workflow, return existing token
    case Map.get(state.resource_hints, key_str) do
      %{holder: holder} = hint when holder == current_holder ->
        {:ok, hint.token, state}

      _ ->
        token = generate_token()

        import Ecto.Query

        query =
          from(r in "resources",
            where: r.key == ^key_str and r.status == "available",
            update: [set: [status: "held", holder: ^inspect(state.workflow_pid || self()), token: ^token, locked_at: fragment("NOW()")]]
          )

        case repo().update_all(query, []) do
          {count, _} when count > 0 ->
            hint = %{holder: inspect(state.workflow_pid || self()), token: token, locked_at: DateTime.utc_now()}
            new_state = Map.put(state, :resource_hints, Map.put(state.resource_hints || %{}, key_str, hint))
            {:ok, token, new_state}

          _ ->
            {:error, :not_available, state}
        end
    end
  end

  @doc """
  Release a held resource hint.
  
  This is the public API for releasing resource hints outside of workflow transactions.
  Use this when you need to manually release resources acquired via acquire_hint/3.
  
  ## Examples
  
      {:ok, new_state} = release_hint(state, "gpu", token)
      {:error, :token_mismatch, state} = release_hint(state, "gpu", "wrong_token")
  """
  def release_hint(state, resource_key, token) do
    state = init_state(state)
    key_str = to_string(resource_key)

    case Map.get(state.resource_hints, key_str) do
      %{token: ^token} ->
        import Ecto.Query

        query =
          from(r in "resources",
            where: r.key == ^key_str and r.token == ^token,
            update: [set: [status: "available", holder: nil, token: nil, locked_at: nil]]
          )

        case repo().update_all(query, []) do
          {count, _} when count >= 0 ->
            new_state = %{state | resource_hints: Map.delete(state.resource_hints, key_str)}
            {:ok, new_state}

          other ->
            {:error, other, state}
        end

      _ ->
        {:error, :token_mismatch, state}
    end
  end

  # Acquire hint within a transaction context (uses transaction's repo instead of module-level repo/0).
  # Returns {:ok, token} | {:error, reason} (no state update - handled by caller).
  defp acquire_hint_in_transaction(repo, state, resource_key) do
    key_str = to_string(resource_key)
    current_holder = inspect(state.workflow_pid || self())

    # If already held by this workflow, return existing token
    case Map.get(state.resource_hints, key_str) do
      %{holder: holder} = hint when holder == current_holder ->
        {:ok, hint.token}

      _ ->
        token = generate_token()

        import Ecto.Query

        query =
          from(r in "resources",
            where: r.key == ^key_str and r.status == "available",
            update: [set: [status: "held", holder: ^inspect(state.workflow_pid || self()), token: ^token, locked_at: fragment("NOW()")]]
          )

        case repo.update_all(query, []) do
          {count, _} when count > 0 -> {:ok, token}
          _ -> {:error, :not_available}
        end
    end
  end

  # Release hint within a transaction context (uses transaction's repo instead of module-level repo/0).
  # Returns {:ok, :released} | {:error, reason} (no state update - handled by caller).
  defp release_hint_in_transaction(repo, state, resource_key, token) do
    key_str = to_string(resource_key)

    case Map.get(state.resource_hints, key_str) do
      %{token: ^token} ->
        import Ecto.Query

        query =
          from(r in "resources",
            where: r.key == ^key_str and r.token == ^token,
            update: [set: [status: "available", holder: nil, token: nil, locked_at: nil]]
          )

        case repo.update_all(query, []) do
          {count, _} when count >= 0 -> {:ok, :released}
          other -> {:error, other}
        end

      _ ->
        {:error, :token_mismatch}
    end
  end

  # Simple token generator
  defp generate_token do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp update_job_status(repo, state, ids, status, reason \\ nil) do
    ids = List.wrap(ids) |> Enum.map(&normalize_id/1)

    if Enum.empty?(ids) do
      {:ok, 0}
    else
      table = quote_table(queue_table(state))
      params =
        if reason do
          [status, reason, ids]
        else
          [status, ids]
        end

      sql =
        if reason do
          "UPDATE #{table} SET status = $1, failure_reason = $2, updated_at = NOW() WHERE id = ANY($3)"
        else
          "UPDATE #{table} SET status = $1, failure_reason = NULL, updated_at = NOW() WHERE id = ANY($2)"
        end

      case repo.query(sql, params) do
        {:ok, %Postgrex.Result{num_rows: count}} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp mark_jobs_in_progress(repo, state, ids) do
    ids = List.wrap(ids) |> Enum.map(&normalize_id/1)

    if Enum.empty?(ids) do
      {:ok, 0}
    else
      table = quote_table(queue_table(state))
      sql = "UPDATE #{table} SET status = 'in_progress', updated_at = NOW() WHERE id = ANY($1)"

      case repo.query(sql, [ids]) do
        {:ok, %Postgrex.Result{num_rows: count}} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp queue_table(state) do
    state
    |> Map.get(:queue_name, "embedding_jobs")
    |> to_string()
  end

  defp quote_table(table) do
    escaped = String.replace(table, "\"", "\"\"")
    ~s("#{escaped}")
  end

  defp normalize_id(%{id: id}), do: normalize_id(id)
  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, _} -> value
      :error -> raise ArgumentError, "Unable to parse job id #{inspect(id)}"
    end
  end

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_float(id), do: trunc(id)
  defp normalize_id(other), do: other

  defp repo do
    Application.get_env(:broadway_singularity_flow, :repo, Singularity.Repo)
  end
end
