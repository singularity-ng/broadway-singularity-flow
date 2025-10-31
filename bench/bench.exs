Mix.install([{:benchee, "~> 1.1"}])

# Lightweight bench script comparing a simple QuantumFlow-style push vs Dummy push.
# This script runs locally and writes a summary to bench/results.md.
#
# Usage:
#   mix run packages/broadway_quantum_flow/bench/bench.exs
#
# Notes:
# - The script uses Mix.install to pull Benchee at runtime.
# - It simulates message creation and a lightweight "push" loop for both
#   the QuantumFlow adapter path and a DummyProducer path. This focuses on
#   measuring throughput/latency of the push logic rather than full DB/QuantumFlow I/O.
# - CPU/GPU measurements are best-effort: it queries os_mon (if available)
#   and `nvidia-smi` (if present) for GPU utilization.

defmodule QuantumFlowBench do
  def get_gpu_util do
    case System.cmd("nvidia-smi", ["--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"]) do
      {out, 0} -> String.trim(out)
      _ -> "n/a"
    end
  rescue
    _ -> "n/a"
  end

  def get_cpu_util do
    case :application.ensure_all_started(:os_mon) do
      {:ok, _} ->
        try do
          case :cpu_sup.util() do
            val when is_list(val) -> Enum.map(val, &Float.round(&1, 2)) |> inspect()
            val -> inspect(val)
          end
        rescue
          _ -> "n/a"
        end

      _ ->
        "n/a"
    end
  rescue
    _ -> "n/a"
  end

  # Simulate the QuantumFlow producer path: create messages (maps) and loop through them
  # doing minimal work to emulate "yielding" and bookkeeping.
  def simulate_quantum_flow(count) when is_integer(count) and count > 0 do
    msgs = for i <- 1..count, do: %{id: i, payload: "x", metadata: %{}}

    # Simulate lightweight per-message processing (no I/O).
    Enum.each(msgs, fn msg ->
      _ = msg.id
      _ = msg.payload
      :ok
    end)
  end

  # Simulate DummyProducer path (similar to above, slightly different shape)
  def simulate_dummy(count) when is_integer(count) and count > 0 do
    msgs = for i <- 1..count, do: {i, "x"}

    Enum.each(msgs, fn {id, payload} ->
      _ = id
      _ = payload
      :ok
    end)
  end
end

inputs = %{
  "1_000" => 1_000,
  "10_000" => 10_000
}

# Run the Benchee suite. Short time per input to keep runtime reasonable.
suite = Benchee.run(
  %{
    "quantum_flow_sim" => fn count -> QuantumFlowBench.simulate_quantum_flow(count) end,
    "dummy_sim" => fn count -> QuantumFlowBench.simulate_dummy(count) end
  },
  inputs: inputs,
  time: 2,
  memory_time: 0.5
)

mem = :erlang.memory()
cpu = QuantumFlowBench.get_cpu_util()
gpu = QuantumFlowBench.get_gpu_util()
now = DateTime.utc_now() |> DateTime.to_iso8601()

summary = """
# Bench Results

Run at: #{now}

## System snapshot
- Erlang memory: #{inspect(mem)}
- CPU utilization (os_mon / cpu_sup): #{inspect(cpu)}
- GPU utilization (nvidia-smi): #{inspect(gpu)}

## Benchee summary (inspect)
```
#{inspect(suite, pretty: true)}
```

## Notes
- The benchmark simulates in-memory push loops and does not perform DB or QuantumFlow network I/O.
- For end-to-end production benchmarking (DB, QuantumFlow workflows, resource locks, GPU-bound work),
  run a tailored integration benchmark in a staging environment where the DB, QuantumFlow, and GPU hardware
  are available.

"""

result_path = Path.join([File.cwd!(), "packages", "broadway_quantum_flow", "bench", "results.md"])
File.mkdir_p!(Path.dirname(result_path))
File.write!(result_path, summary)

IO.puts("Bench complete. Results written to #{result_path}")