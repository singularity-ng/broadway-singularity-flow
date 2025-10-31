defmodule Broadway.QuantumFlowProducerTest do
  use ExUnit.Case, async: true
  import Mox

  alias Broadway.Message
  alias Broadway.QuantumFlowProducer
  alias QuantumFlow.Workflow

  setup :verify_on_exit!

  setup do
    # Mock workflow PID
    {:ok, workflow_pid} = start_supervised({Workflow, []})
    %{workflow_pid: workflow_pid}
  end

  describe "start_link/1" do
    test "starts GenServer and QuantumFlow workflow child", %{workflow_pid: _pid} do
      opts = [
        workflow_name: "test_producer",
        queue_name: "test_queue",
        concurrency: 5,
        batch_size: 10,
        quantum_flow_config: [timeout_ms: 300_000],
        resource_hints: [gpu: true]
      ]

      assert {:ok, pid} = QuantumFlowProducer.start_link(opts)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "fails with missing required opts" do
      opts = [queue_name: "test_queue"]  # Missing workflow_name

      assert {:error, {:badarg, _}} = QuantumFlowProducer.start_link(opts)
    end

    test "defaults concurrency and batch_size when not provided" do
      opts = [
        workflow_name: "test_producer",
        queue_name: "test_queue"
      ]

      assert {:ok, pid} = QuantumFlowProducer.start_link(opts)
      assert Process.alive?(pid)
    end
  end

  describe "handle_demand/3" do
    test "enqueues workflow with demand and returns empty list", %{workflow_pid: workflow_pid} do
      expect(Workflow, :start_link, fn _, _, _ -> {:ok, workflow_pid} end)
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, params ->
        assert params.demand == 10
        assert params.batch_size == 16
        :ok
      end)

      state = %{
        workflow_pid: workflow_pid,
        workflow_name: "test",
        queue_name: "test_queue",
        concurrency: 10,
        batch_size: 16,
        quantum_flow_config: [],
        resource_hints: []
      }

      assert {:noreply, [], ^state} = QuantumFlowProducer.handle_demand(10, 0, state)
    end

    test "handles high concurrency demand", %{workflow_pid: workflow_pid} do
      expect(Workflow, :start_link, fn _, _, _ -> {:ok, workflow_pid} end)
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, params ->
        assert params.demand == 100
        assert params.batch_size == 16
        :ok
      end)

      state = %{
        workflow_pid: workflow_pid,
        workflow_name: "test",
        queue_name: "test_queue",
        concurrency: 50,
        batch_size: 16,
        quantum_flow_config: [],
        resource_hints: []
      }

      assert {:noreply, [], ^state} = QuantumFlowProducer.handle_demand(100, 0, state)
    end
  end

  describe "handle_failure/4" do
    test "updates workflow to requeue failed messages", %{workflow_pid: workflow_pid} do
      expect(Workflow, :update, fn ^workflow_pid, :requeue, %{id: 1, reason: :test_error} -> :ok end)
      expect(Workflow, :update, fn ^workflow_pid, :requeue, %{id: 2, reason: :test_error} -> :ok end)

      batch = [
        %Message{data: {1, :data1}},
        %Message{data: {2, :data2}}
      ]

      state = %{workflow_pid: workflow_pid}

      assert {:noreply, ^state} = QuantumFlowProducer.handle_failure({:basic, :test_error}, batch, nil, state)
    end

    test "handles empty batch failure gracefully", %{workflow_pid: workflow_pid} do
      batch = []

      state = %{workflow_pid: workflow_pid}

      assert {:noreply, ^state} = QuantumFlowProducer.handle_failure({:basic, :test_error}, batch, nil, state)
    end

    test "handles workflow update failure", %{workflow_pid: workflow_pid} do
      expect(Workflow, :update, fn ^workflow_pid, :requeue, %{id: 1, reason: :test_error} -> {:error, :update_failed} end)

      batch = [%Message{data: {1, :data1}}]

      state = %{workflow_pid: workflow_pid}

      # Should still return {:noreply, state} even if update fails
      assert {:noreply, ^state} = QuantumFlowProducer.handle_failure({:basic, :test_error}, batch, nil, state)
    end
  end

  describe "handle_info/2" do
    test "pushes yielded messages to Broadway", %{workflow_pid: workflow_pid} do
      messages = [
        %Message{data: {1, :data1}, metadata: %{}},
        %Message{data: {2, :data2}, metadata: %{}}
      ]

      state = %{workflow_pid: workflow_pid}

      assert {:noreply, ^messages, ^state} = QuantumFlowProducer.handle_info({:workflow_yield, messages}, state)
    end

    test "handles empty message yield", %{workflow_pid: workflow_pid} do
      messages = []

      state = %{workflow_pid: workflow_pid}

      assert {:noreply, ^messages, ^state} = QuantumFlowProducer.handle_info({:workflow_yield, messages}, state)
    end
  end

  describe "resource hints" do
    test "passes resource hints to workflow state", %{workflow_pid: workflow_pid} do
      opts = [
        workflow_name: "test_producer",
        queue_name: "test_queue",
        resource_hints: [gpu: true, cpu_cores: 4]
      ]

      expect(Workflow, :start_link, fn "test_producer", Broadway.QuantumFlowProducer.Workflow, state ->
        assert state.resource_hints == [gpu: true, cpu_cores: 4]
        {:ok, workflow_pid}
      end)

      assert {:ok, _pid} = QuantumFlowProducer.start_link(opts)
    end

    test "defaults to empty resource hints", %{workflow_pid: workflow_pid} do
      opts = [
        workflow_name: "test_producer",
        queue_name: "test_queue"
      ]

      expect(Workflow, :start_link, fn "test_producer", Broadway.QuantumFlowProducer.Workflow, state ->
        assert state.resource_hints == []
        {:ok, workflow_pid}
      end)

      assert {:ok, _pid} = QuantumFlowProducer.start_link(opts)
    end
  end

  describe "error scenarios" do
    test "handles workflow start failure", %{workflow_pid: _workflow_pid} do
      opts = [
        workflow_name: "test_producer",
        queue_name: "test_queue"
      ]

      expect(Workflow, :start_link, fn _, _, _ -> {:error, :workflow_failed} end)

      assert {:error, :workflow_failed} = QuantumFlowProducer.start_link(opts)
    end

    test "handles invalid opts gracefully" do
      opts = [
        workflow_name: "",
        queue_name: "test_queue"
      ]

      # Should fail due to empty workflow_name
      assert {:error, {:badarg, _}} = QuantumFlowProducer.start_link(opts)
    end
  end
end
