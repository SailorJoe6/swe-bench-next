# MCP Docker Exec Bridge

This document describes the Phase 2 MCP bridge component implemented at:

- `scripts/mcp-docker-exec-server.py`

The script is a minimal stdio MCP server used to route shell command execution into a prebound runtime container.

## Scope

- Python stdlib only (no external package dependency)
- Exposes exactly one tool: `mcp-docker-exec`
- Requires fixed startup bindings:
  - runtime container name (`--container-name` or `SWE_BENCH_RUNTIME_CONTAINER_NAME`)
  - container workdir (`--workdir` or `SWE_BENCH_RUNTIME_CONTAINER_WORKDIR` / `SWE_BENCH_CONTAINER_WORKDIR`)
- Executes commands with:
  - `docker exec -i -w <workdir> <container> /bin/sh -lc <command>`
- Returns structured command results:
  - `exit_code`
  - raw `stdout`
  - raw `stderr`

## Current Integration State

As of February 25, 2026, this bridge is integrated into `scripts/start-swebench.sh` Phase execution:

- Codex runs on host (`codex exec -p local --dangerously-bypass-approvals-and-sandbox`)
- Per invocation, the runner injects config overrides to:
  - disable built-in shell tools
  - register a deterministic stdio MCP server binding to the run's runtime container/workdir
- Shell command execution is routed through `mcp-docker-exec` into the prebound runtime container

## Validation

Phase 2 bridge behavior is covered by:

- `tests/test_mcp_docker_exec_server.sh`

The test suite validates:

- startup binding validation failures
- MCP `initialize`/`tools/list`/`tools/call` protocol flow
- single-tool surface (`mcp-docker-exec`)
- exact docker exec argument path
- passthrough of `exit_code`, `stdout`, and `stderr`
