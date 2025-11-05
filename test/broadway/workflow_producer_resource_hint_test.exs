defmodule Broadway.SingularityWorkflowsProducerResourceHintTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  # Define a minimal repo behaviour for the test so Mox can mock it
  defmodule RepoBehaviour do
    @callback update_all(any(), any()) :: any()
    @callback all(any()) :: any()
    @callback one(any()) :: any()
    @callback transaction(any()) :: any()
  end

  Mox.defmock(Singularity.RepoMock, for: RepoBehaviour)

  setup do
    # Point the workflow's repo() helper to the mock
    Application.put_env(:broadway_singularity_flow, :repo, Singularity.RepoMock)
    :ok
  end

  test "acquire_hint reserves DB row and caches token" do
    token = "tok123"

    # transaction will succeed and return a reservation token for reserve_gpu
    expect(Singularity.RepoMock, :transaction, fn _multi ->
      {:ok, %{reserve_gpu: token, mark_in_progress: 1, yield_messages: :ok}}
    end)

    jobs = [%{id: 1, data: %{}, metadata: %{resource_key: "gpu"}}]

    batches = [
      [
        %Broadway.Message{
          data: {1, %{}},
          metadata: %{resource_key: "gpu"},
          acknowledger: {Broadway.SingularityWorkflowsProducer.Workflow, 1}
        }
      ]
    ]

    state = %{batches: batches, jobs: jobs, workflow_pid: self(), resource_hints: %{}, yielded_job_hints: %{}}

    assert {:next, :wait_acks, new_state} = Broadway.SingularityWorkflowsProducer.Workflow.yield_and_commit(state)

    assert Map.has_key?(new_state.resource_hints, "gpu")
    assert Map.get(new_state.resource_hints, "gpu").token == token

    assert Map.get(new_state.yielded_job_hints, 1) == {"gpu", token}
  end

  test "failed acquire_hint prevents message send and job not yielded" do
    # transaction simulates reservation failure
    expect(Singularity.RepoMock, :transaction, fn _multi ->
      {:error, :reserve_gpu, {:resource_unavailable, "gpu"}, %{}}
    end)

    jobs = [%{id: 2, data: %{}, metadata: %{resource_key: "gpu"}}]

    batches = [
      [
        %Broadway.Message{
          data: {2, %{}},
          metadata: %{resource_key: "gpu"},
          acknowledger: {Broadway.SingularityWorkflowsProducer.Workflow, 2}
        }
      ]
    ]

    state = %{batches: batches, jobs: jobs, workflow_pid: self(), resource_hints: %{}, yielded_job_hints: %{}}

    assert {:halt, {:error, {:resource_unavailable, "gpu"}}, ^state} = Broadway.SingularityWorkflowsProducer.Workflow.yield_and_commit(state)
  end

  test "ack releases hint and marks job completed" do
    token = "tok-ack"

    # transaction for release + mark completed
    expect(Singularity.RepoMock, :transaction, fn _multi ->
      {:ok, %{release_resource: 1, mark_completed: 1}}
    end)

    state = %{
      resource_hints: %{"gpu" => %{holder: "pid", token: token, locked_at: DateTime.utc_now()}},
      yielded_job_hints: %{3 => {"gpu", token}},
      workflow_pid: self()
    }

    assert {:ok, new_state} = Broadway.SingularityWorkflowsProducer.Workflow.handle_update(:ack, %{id: 3}, state)

    refute Map.has_key?(new_state.resource_hints, "gpu")
    refute Map.has_key?(new_state.yielded_job_hints, 3)
  end
end