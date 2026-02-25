# Project Status

As of **February 25, 2026**, this repository has two completed initiatives with different runtime statuses.

## Status Summary

- **Phase 3 (SWE-Agent on SWE-Bench Multilingual, ARM64): complete and closed**
  - 299 of 300 SWE-Bench Multilingual test instances were ported and executed on ARM64.
  - Outputs are available under `results/phase3/`.
- **Phase 5 (`swe-ralph` Ralph + Codex runner): implementation and MCP-routing closeout complete, limited live evaluation replay complete**
  - Runner architecture is finalized around host-run Codex with MCP-routed shell execution into deterministic runtime containers.
  - Plan-defined validation is complete (`tests/test_start_swebench.sh`, `tests/test_run_swebench_batch.sh`, `tests/test_mcp_docker_exec_server.sh`).
  - One live SWE-Bench replay/evaluation was run for `google__gson-2024` using a Phase 5-produced patch (resolved).
  - A separate live single-instance integration run against a known Phase 3 failed ID (`preactjs__preact-2896`) exposed MCP startup timeout behavior; root cause and fix were merged on February 25, 2026 (MCP bridge transport compatibility).
  - Metadata bootstrap path in `start-swebench.sh` has been aligned with the Phase 3 multilingual dataset source contract (`swe-bench/SWE-Bench_Multilingual`, split-only load).
  - A full Phase 5 benchmark-scale run has not yet been executed.

## What "Validated" Means Here

For Phase 5, "validated" refers to implementation/contract checks (script syntax and regression tests) plus architecture closeout for host-run Codex + MCP shell routing. It is distinct from full benchmark execution. Live checks have now included both one replay/evaluation (`google__gson-2024`) and one failed-instance integration probe (`preactjs__preact-2896`), but broad benchmark validation remains pending.

## Source-of-Truth Locations

- Phase 3 workflow and ARM64 execution docs:
  - `docs/guides/quickstart.md`
  - `docs/arm64-support/README.md`
- Phase 5 runner behavior contract:
  - `docs/implementation/phase5-runner.md`
- Archived Phase 5 planning and completion record:
  - `.ralph/plans/archive/swe-ralph/SPECIFICATION.md`
  - `.ralph/plans/archive/swe-ralph/EXECUTION_PLAN.md`
