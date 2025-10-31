defmodule Broadway.QuantumFlowProducerErrorTest do
  use ExUnit.Case, async: true
  import Mox

  alias Broadway.Message
  alias Broadway.QuantumFlowProducer
  alias QuantumFlow.Workflow

  setup :verify_on_exit!

  setup do
    {:ok, workflow_pid} = start_supervised({Workflow, []})
    %{workflow_pid: workflow_pid}
  end

  describe "database failures and update errors" do
    test "handle_failure continues gracefully when Workflow.update returns db error", %{workflow_pid: workflow_pid} do
      expect(Workflow, :update, fn ^workflow_pid, :requeue, %{id: 1, reason: :db_error} ->
        {:error, :db_connection_lost}
      end)

      batch = [%Message{data: {1, :payload}}]
      state = %{workflow_pid: workflow_pid}

      # Should not crash and should return {:noreply, state}
      assert {:noreply, ^state} = QuantumFlowProducer.handle_failure({:basic, :db_error}, batch, nil, state)
    end
  end

  describe "QuantumFlow timeouts and enqueue failures" do
    test "handle_demand tolerates QuantumFlow enqueue timeout", %{workflow_pid: workflow_pid} do
      expect(Workflow, :start_link, fn _, _, _ -> {:ok, workflow_pid} end)
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 50, batch_size: 16} ->
        {:error, :timeout}
      end)

      state = %{
        workflow_pid: workflow_pid,
        workflow_name: "t",
        queue_name: "q",
        concurrency: 10,
        batch_size: 16,
        quantum_flow_config: [],
        resource_hints: []
      }

      # Producer should not crash; it will return noreply and empty list
      assert {:noreply, [], ^state} = QuantumFlowProducer.handle_demand(50, 0, state)
    end
  end

  describe "queue exhaustion (no pending jobs)" do
    test "handle_info with empty yield is handled without pushing messages", %{workflow_pid: workflow_pid} do
      messages = []
      state = %{workflow_pid: workflow_pid}

      expect(Broadway, :push_messages, fn Broadway.QuantumFlowProducer, ^messages -> :ok end)

      assert {:noreply, ^state} = QuantumFlowProducer.handle_info({:workflow_yield, messages}, state)
    end
  end

  describe "resource lock conflicts and recovery" do
    test "start_link returns error when workflow cannot acquire resource lock" do
      # Simulate Workflow.start_link failing due to resource lock conflict
      expect(Workflow, :start_link, fn _, _, _ -> {:error, :resource_locked} end)

      opts = [
        workflow_name: "locked_producer",
        queue_name: "jobs",
        resource_hints: [gpu: true]
      ]

      assert {:error, :resource_locked} = QuantumFlowProducer.start_link(opts)
    end

    test "producer recovers when a transient resource conflict is represented as enqueue error", %{workflow_pid: workflow_pid} do
      expect(Workflow, :start_link, fn _, _, _ -> {:ok, workflow_pid} end)
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, _ -> {:error, :resource_conflict} end)

      state = %{
        workflow_pid: workflow_pid,
        workflow_name: "t",
        queue_name: "q",
        concurrency: 10,
        batch_size: 16,
        quantum_flow_config: [],
        resource_hints: [gpu: true]
      }

      # Should tolerate enqueue resource_conflict and not crash
      assert {:noreply, [], ^state} = QuantumFlowProducer.handle_demand(20, 0, state)
    end
  end

  describe "graceful degradation and eventual recovery" do
    test "multiple transient errors do not crash the GenServer", %{workflow_pid: workflow_pid} do
      # Simulate a sequence: first timeout, then successful enqueue
      expect(Workflow, :start_link, fn _, _, _ -> {:ok, workflow_pid} end)
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 5, batch_size: 16} -> {:error, :timeout} end)
      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 5, batch_size: 16} -> :ok end)

      state = %{
        workflow_pid: workflow_pid,
        workflow_name: "t",
        queue_name: "q",
        concurrency: 10,
        batch_size: 16,
        quantum_flow_config: [],
        resource_hints: []
      }

      # First call: timeout
      assert {:noreply, [], ^state} = QuantumFlowProducer.handle_demand(5, 0, state)
      # Second call: success
      assert {:noreply, [], ^state} = QuantumFlowProducer.handle_demand(5, 0, state)
    end
  end
end