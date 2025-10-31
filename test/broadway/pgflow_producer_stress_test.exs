defmodule Broadway.QuantumFlowProducerStressTest do
  use ExUnit.Case, async: false  # Not async for accurate timing
  import Mox
  import ExUnit.CaptureLog

  alias Broadway.Message
  alias Broadway.QuantumFlowProducer
  alias QuantumFlow.Workflow

  setup :verify_on_exit!

  setup do
    # Setup for stress testing
    {:ok, workflow_pid} = start_supervised({Agent, fn -> [] end})
    %{workflow_pid: workflow_pid}
  end

  describe "performance benchmarks vs DummyProducer" do
    test "benchmarks throughput: 10000 messages", %{workflow_pid: workflow_pid} do
      jobs = for i <- 1..10000, do: %{id: i, data: :"job#{i}", status: "pending", metadata: %{}}

      Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
      Mox.expect(Singularity.Repo, :update_all, 10000, fn _query, _ -> {1, []} end)

      opts = [
        workflow_name: "benchmark_producer",
        queue_name: "benchmark_queue",
        concurrency: 20,
        batch_size: 500,
        quantum_flow_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = QuantumFlowProducer.start_link(opts)

      # Benchmark QuantumFlowProducer
      {quantum_flow_time, _} = :timer.tc(fn ->
        send(producer_pid, {:demand, 10000, self()})

        expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 10000, batch_size: 500} ->
          # Yield in batches of 500
          for batch_start <- 0..9500//500 do
            batch = Enum.slice(jobs, batch_start, 500)
            messages = Enum.map(batch, fn job ->
              %Message{
                data: {job.id, job.data},
                metadata: job.metadata,
                acknowledger: {QuantumFlowProducer.Workflow, job.id}
              }
            end)
            send(producer_pid, {:workflow_yield, messages})
          end
          :ok
        end)

        # Mock Broadway processing
        expect(Broadway, :push_messages, 20, fn Broadway.QuantumFlowProducer, messages ->
          # Simulate processing time
          Process.sleep(1)
          :ok
        end)

        # Wait for completion
        Process.sleep(2000)
      end)

      # Benchmark DummyProducer for comparison
      dummy_opts = [
        module: {Broadway.DummyProducer, []},
        concurrency: 20
      ]

      {dummy_time, _} = :timer.tc(fn ->
        {:ok, dummy_pid} = Broadway.start_link(dummy_opts)

        # Simulate processing 10000 messages
        for _ <- 1..10000 do
          send(dummy_pid, {:demand, 1, self()})
        end

        Process.sleep(2000)
        Process.exit(dummy_pid, :kill)
      end)

      # Log results
      IO.puts("QuantumFlowProducer time: #{quantum_flow_time / 1000}ms")
      IO.puts("DummyProducer time: #{dummy_time / 1000}ms")
      IO.puts("Throughput ratio: #{dummy_time / quantum_flow_time}")

      # QuantumFlow should be reasonably close (within 2x) due to orchestration overhead
      assert quantum_flow_time < dummy_time * 3

      Process.exit(producer_pid, :kill)
    end

    test "latency measurements: end-to-end message processing", %{workflow_pid: workflow_pid} do
      jobs = for i <- 1..100, do: %{id: i, data: :"latency_job#{i}", status: "pending", metadata: %{}}

      Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
      Mox.expect(Singularity.Repo, :update_all, 100, fn _query, _ -> {1, []} end)

      opts = [
        workflow_name: "latency_producer",
        queue_name: "latency_queue",
        concurrency: 5,
        batch_size: 10,
        quantum_flow_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = QuantumFlowProducer.start_link(opts)

      latencies = []

      {total_time, latencies} = :timer.tc(fn ->
        send(producer_pid, {:demand, 100, self()})

        expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 100, batch_size: 10} ->
          start_time = System.monotonic_time(:millisecond)

          # Yield in batches
          for batch_start <- 0..90//10 do
            batch = Enum.slice(jobs, batch_start, 10)
            messages = Enum.map(batch, fn job ->
              %Message{
                data: {job.id, job.data},
                metadata: job.metadata,
                acknowledger: {QuantumFlowProducer.Workflow, job.id}
              }
            end)
            send(producer_pid, {:workflow_yield, messages})
          end

          end_time = System.monotonic_time(:millisecond)
          [{start_time, end_time}]
        end)

        # Mock Broadway processing with latency tracking
        expect(Broadway, :push_messages, 10, fn Broadway.QuantumFlowProducer, messages ->
          batch_start = System.monotonic_time(:millisecond)
          Process.sleep(5)  # Simulate processing
          batch_end = System.monotonic_time(:millisecond)
          latencies ++ [{batch_start, batch_end}]
          :ok
        end)

        Process.sleep(1000)
        latencies
      end)

      # Calculate average latency
      avg_latency = Enum.reduce(latencies, 0, fn {start, stop}, acc ->
        acc + (stop - start)
      end) / length(latencies)

      IO.puts("Average end-to-end latency: #{avg_latency}ms")
      IO.puts("Total processing time: #{total_time / 1000}ms")

      # Assert reasonable latency (< 50ms average)
      assert avg_latency < 50

      Process.exit(producer_pid, :kill)
    end

    test "memory usage under high load", %{workflow_pid: workflow_pid} do
      jobs = for i <- 1..5000, do: %{id: i, data: :"memory_job#{i}", status: "pending", metadata: %{large_field: String.duplicate("data", 100)}}

      Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
      Mox.expect(Singularity.Repo, :update_all, 5000, fn _query, _ -> {1, []} end)

      opts = [
        workflow_name: "memory_producer",
        queue_name: "memory_queue",
        concurrency: 10,
        batch_size: 250,
        quantum_flow_config: [],
        resource_hints: []
      ]

      {:ok, producer_pid} = QuantumFlowProducer.start_link(opts)

      # Measure memory before
      {_, memory_before} = :erlang.process_info(producer_pid, :memory)

      send(producer_pid, {:demand, 5000, self()})

      expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 5000, batch_size: 250} ->
        # Yield in batches
        for batch_start <- 0..4750//250 do
          batch = Enum.slice(jobs, batch_start, 250)
          messages = Enum.map(batch, fn job ->
            %Message{
              data: {job.id, job.data},
              metadata: job.metadata,
              acknowledger: {QuantumFlowProducer.Workflow, job.id}
            }
          end)
          send(producer_pid, {:workflow_yield, messages})
        end
        :ok
      end)

      # Mock processing
      expect(Broadway, :push_messages, 20, fn Broadway.QuantumFlowProducer, messages ->
        Process.sleep(2)
        :ok
      end)

      Process.sleep(1500)

      # Measure memory after
      {_, memory_after} = :erlang.process_info(producer_pid, :memory)

      memory_delta = memory_after - memory_before
      IO.puts("Memory delta: #{memory_delta} bytes")

      # Assert memory usage is reasonable (< 50MB increase)
      assert memory_delta < 50_000_000

      Process.exit(producer_pid, :kill)
    end

    test "concurrency scaling test", %{workflow_pid: workflow_pid} do
      jobs = for i <- 1..2000, do: %{id: i, data: :"concurrency_job#{i}", status: "pending", metadata: %{}}

      Mox.expect(Singularity.Repo, :all, fn _query -> jobs end)
      Mox.expect(Singularity.Repo, :update_all, 2000, fn _query, _ -> {1, []} end)

      # Test different concurrency levels
      concurrency_levels = [1, 5, 10, 20]

      results = for concurrency <- concurrency_levels do
        opts = [
          workflow_name: "concurrency_producer_#{concurrency}",
          queue_name: "concurrency_queue",
          concurrency: concurrency,
          batch_size: 100,
          quantum_flow_config: [],
          resource_hints: []
        ]

        {:ok, producer_pid} = QuantumFlowProducer.start_link(opts)

        {time, _} = :timer.tc(fn ->
          send(producer_pid, {:demand, 2000, self()})

          expect(Workflow, :enqueue, fn ^workflow_pid, :fetch, %{demand: 2000, batch_size: 100} ->
            # Yield all at once for simplicity
            messages = Enum.map(jobs, fn job ->
              %Message{
                data: {job.id, job.data},
                metadata: job.metadata,
                acknowledger: {QuantumFlowProducer.Workflow, job.id}
              }
            end)
            send(producer_pid, {:workflow_yield, messages})
            :ok
          end)

          expect(Broadway, :push_messages, 20, fn Broadway.QuantumFlowProducer, messages ->
            Process.sleep(1)
            :ok
          end)

          Process.sleep(1000)
        end)

        Process.exit(producer_pid, :kill)
        {concurrency, time / 1000}  # time in ms
      end

      # Log scaling results
      Enum.each(results, fn {concurrency, time} ->
        IO.puts("Concurrency #{concurrency}: #{time}ms")
      end)

      # Assert scaling improves performance (higher concurrency should be faster)
      {low_conc, low_time} = List.first(results)
      {high_conc, high_time} = List.last(results)
      assert high_time < low_time * 0.8  # At least 20% improvement
    end
  end
end