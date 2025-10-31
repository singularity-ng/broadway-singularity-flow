# Changelog

All notable changes to this project will be documented in this file.

## 0.1.0 - Initial release

- Initial implementation of Broadway.QuantumFlowProducer:
  - GenServer-based Broadway producer integrating with QuantumFlow workflows.
  - Workflow implementation for fetch, batch, yield, ack, and requeue handling.
  - Resource hints support (GPU acquisition placeholder).
- Tests:
  - Unit tests for producer behavior and failure handling.
  - Integration tests simulating end-to-end demand → yield → ack flows.
  - Stress tests for performance and concurrency scenarios.
- Documentation:
  - README with API, migration examples, troubleshooting, and deployment notes.
  - ARCHITECTURE.md describing system design and trade-offs.
  - MIGRATION_GUIDE.md with step-by-step migration instructions.

### Deployment notes (v0.1.0)
- Minimal production checklist:
  - Apply DB migrations for queue tables and indexes before rollout.
  - Configure QuantumFlow timeouts and retries (PGFLOW_TIMEOUT_MS, PGFLOW_RETRIES).
  - Implement and test resource acquisition (GPU/locks) with timeouts and fallbacks.
  - Set up monitoring for queue depth, throughput, error rate, and latency.
  - Prepare rollback/runbook and backup strategy for pending jobs.
- Recommended environment variables:
  - DATABASE_URL / ECTO repo DSN, POOL_SIZE
  - PGFLOW_TIMEOUT_MS, PGFLOW_RETRIES
  - BROADWAY_CONCURRENCY, BROADWAY_BATCH_SIZE
  - GPU_LOCK_TABLE (if using DB locks)
- Notes:
  - Benchmarks included under bench/ are microbenchmarks; run end-to-end staging benchmarks (DB, QuantumFlow, GPU) before production.
  - Use Nix shells for reproducible builds and testing.