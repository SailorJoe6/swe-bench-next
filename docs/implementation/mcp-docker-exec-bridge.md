# MCP Docker Exec Bridge

This document describes the Phase 2 MCP bridge component implemented at:

- `scripts/mcp-docker-exec-server.py`

The script is a minimal stdio MCP server used to route shell command execution into a prebound runtime container.

## Scope

- Python stdlib only (no external package dependency)
- Exposes exactly one tool: `mcp-docker-exec`
- Supports both stdio JSON-RPC wire formats used in this repo:
  - `Content-Length` framed messages
  - newline-delimited JSON-RPC messages
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

## Integration Findings (February 25, 2026)

- A live Phase 5 single-instance integration run (`preactjs__preact-2896`) initially hit MCP startup timeouts even though the bridge process launched.
- Root cause: transport mismatch. Codex MCP client used newline-delimited JSON-RPC startup messages while the bridge only accepted `Content-Length` framed messages.
- Fix implemented: bridge now auto-detects and handles both transport formats.
- Result: direct Codex + MCP startup now reaches `mcp ... ready` with the same runner-injected config pattern.

## Validation

Phase 2 bridge behavior is covered by:

- `tests/test_mcp_docker_exec_server.sh`

The test suite validates:

- startup binding validation failures
- MCP `initialize`/`tools/list`/`tools/call` protocol flow for both transports
- single-tool surface (`mcp-docker-exec`)
- exact docker exec argument path
- passthrough of `exit_code`, `stdout`, and `stderr`
