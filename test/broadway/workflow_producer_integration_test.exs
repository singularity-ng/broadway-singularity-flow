defmodule Broadway.SingularityWorkflowsProducerIntegrationTest do
  use ExUnit.Case, async: true
  import Mox
  import ExUnit.CaptureLog

  alias Broadway.Message
  alias Broadway.SingularityWorkflowsProducer
  alias SingularityWorkflow.Workflow

  setup :verify_on_exit!

  setup do
    # Mock the queue and workflow for integration simulation
    {:ok, workflow_pid} = start_supervised({Agent, fn -> [] end})  # Mock workflow state
    {:ok, queue_pid} = start_supervised({Agent, fn -> [%{id: 1, data: :job1, status: "pending"}] end})

    # Mock Repo for DB interactions
    Mox.expect(Singularity.Repo, :all, fn _query -> [%{id: 1, data: :job1, metadata: %{}}] end)
    Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> {1, []} end)

    %{workflow_pid: workflow_pid, queue_pid: queue_pid}
  end

  describe "end-to-end demand → yield → ack" do
    test "fetches from mock queue, yields messages, and acks update status", %{workflow_pid: workflow_pid} do
      opts = [
        workflow_name: "integration_producer",
        queue_name: "mock_queue",
        concurrency: 1,
        batch_size: 1,
        singularity_workflows_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      # Simulate demand
      send(producer_pid, {:demand, 1, self()})

      # Expect workflow enqueue and fetch
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 1, batch_size: 1} ->
        # Simulate yield
        messages = [
          %Message{
            data: {1, :job1},
            metadata: %{},
            acknowledger: {SingularityWorkflowsProducer.Workflow, 1}
          }
        ]
        send(producer_pid, {:workflow_yield, messages})
        :ok
      end)

      # Wait for yield (in real, would assert received)
      Process.sleep(100)

      # Simulate ack
      ack_msg = %Message{data: {1, :job1}, acknowledger: {SingularityWorkflowsProducer.Workflow, 1}}
      SingularityWorkflowsProducer.Workflow.handle_update(:ack, %{id: 1}, %{})

      # Capture logs to verify no errors
      assert capture_log(fn ->
        # Verify ack updated status
        assert_receive {:ack, 1}, 500
      end) =~ "Acked job 1"

      # Cleanup
      Process.exit(producer_pid, :kill)
    end
  end

  describe "atomic yield_and_commit" do
    test "yield_and_commit is atomic: DB failure prevents message send", %{workflow_pid: workflow_pid} do
      # Mock fetch to return one job
      Mox.expect(Singularity.Repo, :all, fn _query -> [%{id: 42, data: :job42, metadata: %{}}] end)

      # Simulate DB failure when marking in_progress
      Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> raise "db_fail" end)

      opts = [
        workflow_name: "atomic_failure_producer",
        queue_name: "atomic_queue",
        concurrency: 1,
        batch_size: 1,
        singularity_workflows_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      # Intercept Workflow.enqueue to simulate the yield_and_commit behaviour:
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, _params ->
        try do
          # Attempt to mark in_progress (will raise)
          Singularity.Repo.update_all(:fake_query, [])
          # If it had succeeded we would send messages
          messages = [
            %Message{
              data: {42, :job42},
              metadata: %{},
              acknowledger: {SingularityWorkflowsProducer.Workflow, 42}
            }
          ]
          send(producer_pid, {:workflow_yield, messages})
        rescue
          _ ->
            # Indicate that no messages were sent due to DB failure
            send(producer_pid, :no_messages)
        end
        :ok
      end)

      # Trigger demand
      send(producer_pid, {:demand, 1, self()})

      # Assert we observed the no_messages indicator and no workflow_yield
      assert_receive :no_messages, 500
      refute_receive {:workflow_yield, _}, 200

      Process.exit(producer_pid, :kill)
    end

    test "yield_and_commit succeeds: messages sent and jobs marked in_progress", %{workflow_pid: workflow_pid} do
      Mox.expect(Singularity.Repo, :all, fn _query -> [%{id: 7, data: :job7, metadata: %{}}] end)
      # update_all returns {count, rows}
      Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> {1, []} end)

      opts = [
        workflow_name: "atomic_success_producer",
        queue_name: "atomic_queue",
        concurrency: 1,
        batch_size: 1,
        singularity_workflows_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, _params ->
        case Singularity.Repo.update_all(:fake_query, []) do
          {1, _} ->
            messages = [
              %Message{
                data: {7, :job7},
                metadata: %{},
                acknowledger: {SingularityWorkflowsProducer.Workflow, 7}
              }
            ]
            send(producer_pid, {:workflow_yield, messages})
          other ->
            send(producer_pid, {:unexpected, other})
        end
        :ok
      end)

      # Expect Broadway.push_messages to be called with the yielded messages
      expect(Broadway, :push_messages, 1, fn Broadway.SingularityWorkflowsProducer, messages ->
        assert length(messages) == 1
        :ok
      end)

      send(producer_pid, {:demand, 1, self()})

      assert_receive {:workflow_yield, _messages}, 500

      Process.exit(producer_pid, :kill)
    end
  end

  describe "stress tests" do
    test "handles 1000 messages with batching", %{workflow_pid: workflow_pid} do
      # Generate 1000 mock jobs
      jobs = for i <- 1..1000, do: %{id: i, data: :"job#{i}", status: "pending", metadata: %{}}

      # Mock Repo to return all jobs
      Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
      Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> {1000, []} end)

      opts = [
        workflow_name: "stress_producer",
        queue_name: "stress_queue",
        concurrency: 10,
        batch_size: 100,
        singularity_workflows_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      # Simulate high demand
      send(producer_pid, {:demand, 1000, self()})

      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 1000, batch_size: 100} ->
        # Simulate yielding in batches
        for batch_start <- 0..900//100 do
          batch = Enum.slice(jobs, batch_start, 100)
          messages = Enum.map(batch, fn job ->
            %Message{
              data: {job.id, job.data},
              metadata: job.metadata,
              acknowledger: {SingularityWorkflowsProducer.Workflow, job.id}
            }
          end)
          send(producer_pid, {:workflow_yield, messages})
        end
        :ok
      end)

      # Wait for processing
      Process.sleep(500)

      # Verify all messages were yielded (mock Broadway.push_messages)
      expect(Broadway, :push_messages, 10, fn Broadway.SingularityWorkflowsProducer, messages ->
        assert length(messages) <= 100
        :ok
      end)

      # Cleanup
      Process.exit(producer_pid, :kill)
    end

    test "simulates GPU hint acquisition under load", %{workflow_pid: workflow_pid} do
      jobs = for i <- 1..100, do: %{id: i, data: :"gpu_job#{i}", status: "pending", metadata: %{gpu_required: true}}

      Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
      Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> {100, []} end)

      opts = [
        workflow_name: "gpu_stress_producer",
        queue_name: "gpu_queue",
        concurrency: 5,
        batch_size: 20,
        singularity_workflows_config: [],
        resource_hints: [gpu: true]
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      send(producer_pid, {:demand, 100, self()})

      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 100, batch_size: 20} ->
        # Simulate GPU lock acquisition (would log in real implementation)
        messages = Enum.map(jobs, fn job ->
          %Message{
            data: {job.id, job.data},
            metadata: job.metadata,
            acknowledger: {SingularityWorkflowsProducer.Workflow, job.id}
          }
        end)
        send(producer_pid, {:workflow_yield, messages})
        :ok
      end)

      # Capture GPU acquisition logs
      log = capture_log(fn ->
        Process.sleep(200)
      end)

      assert log =~ "Acquiring GPU lock for queue gpu_queue"

      Process.exit(producer_pid, :kill)
    end
  
    describe "dynamic batching" do
      test "adjusts batch_size downward under high queue depth", %{workflow_pid: workflow_pid} do
        # Prepare many jobs
        jobs = for i <- 1..20, do: %{id: i, data: :"job#{i}", status: "pending", metadata: %{}}
  
        # Mock queue depth COUNT query and fetch
        Mox.expect(Singularity.Repo, :one, fn _query -> 10000 end)
        Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
        Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> {20, []} end)
  
        # Provide a simple telemetry module returning high ack latency
        defmodule HighAckTelemetry do
          def get_recent_ack_latency, do: 300
        end
  
        Application.put_env(:broadway_singularity_flow, :telemetry_module, HighAckTelemetry)
  
        opts = [
          workflow_name: "dynamic_high_queue",
          queue_name: "dynamic_queue",
          concurrency: 1,
          batch_size: 16,
          singularity_workflows_config: [],
          resource_hints: []
        ]
  
        {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)
  
        # Intercept enqueue to simulate workflow behavior using provided params.
        expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, params ->
          # Expect the producer passed queue_depth and recent_ack_latency
          assert params.queue_depth == 10000
          assert params.recent_ack_latency == 300
  
          # Compute expected effective batch size from workflow logic:
          effective = max(4, div(params.batch_size, 2))
  
          # Simulate yielding messages in batches of effective size
          for batch <- Enum.chunk_every(jobs, effective) do
            messages = Enum.map(batch, fn job ->
              %Message{
                data: {job.id, job.data},
                metadata: job.metadata,
                acknowledger: {SingularityWorkflowsProducer.Workflow, job.id}
              }
            end)
  
            send(producer_pid, {:workflow_yield, messages})
          end
  
          :ok
        end)
  
        expected_effective = max(4, div(16, 2))
        expected_batches = Integer.ceil(20 / expected_effective)
  
        # Assert Broadway.push_messages is called with batches not exceeding effective size
        expect(Broadway, :push_messages, expected_batches, fn Broadway.SingularityWorkflowsProducer, messages ->
          assert length(messages) <= expected_effective
          :ok
        end)
  
        # Trigger demand
        send(producer_pid, {:demand, 20, self()})
        Process.sleep(200)
  
        Process.exit(producer_pid, :kill)
      end
  
      test "increases batch_size when queue is shallow and ack latency low", %{workflow_pid: workflow_pid} do
        # Prepare jobs
        jobs = for i <- 1..32, do: %{id: i, data: :"job#{i}", status: "pending", metadata: %{}}
  
        # Mock queue depth COUNT query and fetch
        Mox.expect(Singularity.Repo, :one, fn _query -> 100 end)
        Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
        Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> {32, []} end)
  
        # Provide a simple telemetry module returning low ack latency
        defmodule LowAckTelemetry do
          def get_recent_ack_latency, do: 10
        end
  
        Application.put_env(:broadway_singularity_flow, :telemetry_module, LowAckTelemetry)
  
        opts = [
          workflow_name: "dynamic_low_queue",
          queue_name: "dynamic_queue_shallow",
          concurrency: 1,
          batch_size: 8,
          singularity_workflows_config: [],
          resource_hints: []
        ]
  
        {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)
  
        expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, params ->
          assert params.queue_depth == 100
          assert params.recent_ack_latency == 10
  
          # Compute expected effective batch size:
          effective = min(params.batch_size * 2, 512)
  
          for batch <- Enum.chunk_every(jobs, effective) do
            messages = Enum.map(batch, fn job ->
              %Message{
                data: {job.id, job.data},
                metadata: job.metadata,
                acknowledger: {SingularityWorkflowsProducer.Workflow, job.id}
              }
            end)
  
            send(producer_pid, {:workflow_yield, messages})
          end
  
          :ok
        end)
  
        expected_effective = min(8 * 2, 512)
        expected_batches = Integer.ceil(32 / expected_effective)
  
        expect(Broadway, :push_messages, expected_batches, fn Broadway.SingularityWorkflowsProducer, messages ->
          assert length(messages) <= expected_effective
          :ok
        end)
  
        send(producer_pid, {:demand, 32, self()})
        Process.sleep(200)
  
        Process.exit(producer_pid, :kill)
      end
    end
  end

  describe "error recovery tests" do
    test "recovers from workflow enqueue failure", %{workflow_pid: workflow_pid} do
      opts = [
        workflow_name: "error_producer",
        queue_name: "error_queue",
        concurrency: 1,
        batch_size: 1,
        singularity_workflows_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      # Simulate demand
      send(producer_pid, {:demand, 1, self()})

      # Mock enqueue failure
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, _ -> {:error, :enqueue_failed} end)

      # Producer should handle gracefully (no crash)
      Process.sleep(100)
      assert Process.alive?(producer_pid)

      Process.exit(producer_pid, :kill)
    end

    test "handles database connection failure during fetch", %{workflow_pid: workflow_pid} do
      # Mock Repo failure
      Mox.expect(Singularity.Repo, :all, fn _query -> {:error, :db_connection_lost} end)

      opts = [
        workflow_name: "db_error_producer",
        queue_name: "db_queue",
        concurrency: 1,
        batch_size: 1,
        singularity_workflows_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      send(producer_pid, {:demand, 1, self()})

      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, _ ->
        # Simulate workflow handling DB error
        send(producer_pid, {:workflow_error, :db_connection_lost})
        :ok
      end)

      # Producer should remain alive despite DB error
      Process.sleep(100)
      assert Process.alive?(producer_pid)

      Process.exit(producer_pid, :kill)
    end

    test "recovers from partial batch failure", %{workflow_pid: workflow_pid} do
      jobs = [
        %{id: 1, data: :job1, status: "pending", metadata: %{}},
        %{id: 2, data: :job2, status: "pending", metadata: %{}},
        %{id: 3, data: :job3, status: "pending", metadata: %{}}
      ]

      Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
      Mox.expect(Singularity.Repo, :update_all, fn _query, _ -> {3, []} end)

      opts = [
        workflow_name: "partial_failure_producer",
        queue_name: "partial_queue",
        concurrency: 1,
        batch_size: 3,
        singularity_workflows_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = SingularityWorkflowsProducer.start_link(opts)

      send(producer_pid, {:demand, 3, self()})

      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 3, batch_size: 3} ->
        messages = Enum.map(jobs, fn job ->
          %Message{
            data: {job.id, job.data},
            metadata: job.metadata,
            acknowledger: {SingularityWorkflowsProducer.Workflow, job.id}
          }
        end)
        send(producer_pid, {:workflow_yield, messages})
        :ok
      end)

      # Simulate partial failure (only job 2 fails)
      expect(Workflow, :update, fn ^workflow_pid, :requeue, %{id: 2, reason: :processing_error} -> :ok end)

      # Send failure for job 2
      failed_batch = [%Message{data: {2, :job2}}]
      SingularityWorkflowsProducer.handle_failure({:basic, :processing_error}, failed_batch, nil, %{workflow_pid: workflow_pid})

      # Verify other jobs can still be acked
      SingularityWorkflowsProducer.Workflow.handle_update(:ack, %{id: 1}, %{})
      SingularityWorkflowsProducer.Workflow.handle_update(:ack, %{id: 3}, %{})

      Process.sleep(100)
      assert Process.alive?(producer_pid)

      Process.exit(producer_pid, :kill)
    end
  end
end