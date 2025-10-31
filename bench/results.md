# Benchmark Results (bench/bench.exs)

Status: NOT RUN — runtime tools (Elixir/mix) not available in the current execution environment.
See "How to run" below to produce real results in your dev/staging environment or CI (Nix recommended).

## Summary / Intent
The included benchmark script `packages/broadway_quantum_flow/bench/bench.exs` uses Benchee to run short microbenchmarks comparing the in-memory push/iteration paths that mimic:

- Broadway.QuantumFlowProducer-like path (simulate_quantum_flow)  
- DummyProducer-like path (simulate_dummy)

It runs for inputs:
- 1_000 messages
- 10_000 messages

Measured outputs:
- Throughput (ops/s)
- Iteration latency
- Memory snapshot (Erlang VM memory map)
- CPU utilization (via os_mon/cpu_sup if available)
- GPU utilization (via nvidia-smi if present)

The script writes a summary to this file when executed.

## Current placeholder results
No numeric results available because the script has not been executed here. The repository contains:
- packages/broadway_quantum_flow/bench/bench.exs (Benchee script)

## How to run (recommended — use Nix for reproducible environment)
1. Enter project Nix dev shell (recommended):
   - If your repo uses `nix develop`: run `nix develop` in the repo root.
   - If you use a pinned shell: `nix-shell` / `direnv` as configured by your project.

2. Install dependencies and run bench script:
   - If in a shell with Elixir available:
     - From repo root:
       - mix deps.get
       - mix run ./packages/broadway_quantum_flow/bench/bench.exs
     - Or directly:
       - elixir ./packages/broadway_quantum_flow/bench/bench.exs

3. After successful run, `packages/broadway_quantum_flow/bench/results.md` will be overwritten with a timestamped summary.

Example commands (adjust to your Nix flow):
```bash
# enter nix dev shell (project-specific)
nix develop

# from repo root
mix deps.get
mix run ./packages/broadway_quantum_flow/bench/bench.exs
```

## Notes & guidance for end-to-end benchmarking
- The included script is an in-memory microbenchmark. For production-grade benchmarking you must run an integration benchmark in a staging environment with:
  - A real Postgres instance seeded with 1_000 / 10_000 pending jobs
  - QuantumFlow workflows enabled and using the same workflow config as production
  - Representative worker workloads (CPU/GPU) to measure realistic latency and resource contention
  - System-level monitoring (Prometheus, node_exporter, nvidia-smi telemetry) to capture CPU, memory, and GPU utilization
- Capture results into CI artifacts and into `packages/broadway_quantum_flow/bench/results.md` (the bench script already writes a markdown summary).

## Diagnostic note (why results are missing here)
Attempts to run `mix test` and to execute the bench script in this environment failed due to the absence of `mix` / `elixir` (Exit code 127). Run the commands above inside your Nix dev/CI environment where Elixir is available.
