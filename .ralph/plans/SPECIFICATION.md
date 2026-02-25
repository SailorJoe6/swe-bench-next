# Specification: Use Instance Container as Codex Execution Sandbox

## 1. Purpose

Define a Phase 5 runner enhancement so Codex runs on host while command execution for SWE-Bench work is routed into the instance container via MCP.

This replaces the current "copy Codex into each instance image" model with a deterministic, container-targeted shell tool path.

## 2. Scope and Contract Freeze

This specification is an enhancement to archived Phase 5 contracts in:

- `.ralph/plans/archive/swe-ralph/SPECIFICATION.md`
- `.ralph/plans/archive/swe-ralph/EXECUTION_PLAN.md`

External contract is frozen unless shell-routing swap strictly requires change:

- keep existing runner entrypoints and user-facing CLI contracts
- keep existing per-instance artifacts and manifest behavior
- keep existing status vocabulary and exit semantics
- keep plan/execute/handoff loop behavior

## 3. Baseline (Current Implementation)

Current flow in `scripts/start-swebench.sh`:

1. Resolve image `sweb.eval.arm64.<instance_id>:latest`.
2. Create deterministic runtime container name `swebench-runtime-<sanitized-instance-id>`.
3. Force-remove stale container with same name before create (`docker rm -f <name>`, ignore not-found).
4. Create/start runtime container with explicit `--name`.
5. Execute `codex exec -p local --dangerously-bypass-approvals-and-sandbox` inside that container via `docker exec`.

Implementation checkpoint:

- normal-path codex/bootstrap image mutation has been removed
- host-run Codex + MCP-only shell routing is not implemented yet

## 4. Core Problem

Runtime image mutation and in-image Codex bootstrap are brittle:

- per-image runtime/library differences can break copied binary execution
- image mutation at runtime is operationally hard to reason about
- troubleshooting and reproducibility are weaker than host-executed Codex

## 5. Final Architecture Decisions

1. Codex runtime placement: host.
2. Shell execution backend: MCP only (built-in Codex shell disabled).
3. MCP style: per-run stdio process launched by Codex.
4. MCP implementation: repo-owned minimal Python server (no external Python package dependency).
5. MCP tool surface: exactly one command tool named `mcp-docker-exec`.
6. Target container selection: runner passes exact container name per invocation (no model-side switching, no discovery heuristics).
7. Working directory: fixed by runner per invocation; no command-level cwd override.
8. Command freedom: full parity with current shell freedom (no allowlist/denylist in this iteration).
9. Output contract: return raw stdout/stderr and exact exit code from underlying `docker exec`, with minimal JSON framing.
10. Failure taxonomy: keep existing external reason-code vocabulary; map MCP/route failures to existing `runtime_error` with explicit detail.

## 6. Runner and Container Lifecycle Contract

Runner continues to own lifecycle of runtime containers.

### 6.1 Runtime Container Naming

`start-swebench.sh` must create runtime container name:

- `swebench-runtime-<sanitized-instance-id>`

Sanitization rules:

- lowercase
- replace chars outside `[a-z0-9_.-]` with `-`
- collapse repeated `-`
- trim leading/trailing `-`
- enforce Docker name length constraints deterministically

### 6.2 Collision Policy

Before creating runtime container, runner must force-remove any existing container with the same name:

- `docker rm -f <runtime_name>` (ignore not-found)
- then `docker create --name <runtime_name> ...`

This prevents environment litter and stale-container ambiguity without timestamp suffixes.

### 6.3 Lifecycle Ownership

Keep existing runner behavior:

- create/start runtime container before phase execution
- cleanup runtime container at script exit via existing trap-driven cleanup path

No lifecycle orchestration is added to the MCP server in this iteration.

## 7. Codex Invocation Contract

`start-swebench.sh` continues to invoke Codex with local profile and unattended mode:

- `codex exec -p local --dangerously-bypass-approvals-and-sandbox ...`

Per Codex invocation, runner must pass minimal deterministic `--config` overrides that:

1. disable built-in shell feature
2. define required MCP server launcher for the minimal bridge
3. bind target container/workdir for that run

Design constraints:

- no mutation of global `~/.codex/config.toml` at runtime
- no per-run temp config file requirement
- all critical routing params are explicit on invocation

## 8. MCP Bridge Contract

Add a repo-local Python MCP server script (for example `scripts/mcp-docker-exec-server.py`) with stdio transport.

### 8.1 Startup and Dependencies

- lightweight startup
- Python stdlib only (no extra pip install dependency)
- process launched by Codex as stdio MCP server for each run

### 8.2 Tool Surface

Expose exactly one tool:

- `mcp-docker-exec`

No additional Docker management or orchestration tools in this iteration.

### 8.3 Runtime Binding Inputs

Runner passes binding inputs at launch (via Codex MCP server config) for:

- target container name
- fixed workdir inside container

Tool must reject execution if required binding inputs are missing.

### 8.4 Execution Semantics

For each call:

- execute command using fixed container + workdir
- shell semantics match current behavior (`/bin/sh -lc ...`)
- run as container default user (current behavior parity; root in current images)
- no `-t` interactive terminal allocation

### 8.5 Response Semantics

Return:

- `exit_code` from executed command
- raw `stdout`
- raw `stderr`

No output rewriting or synthetic interpretation beyond required tool response framing.

## 9. Tooling Scope and Context Budget

Keep current useful tool availability and only swap shell path:

- keep `web_search`
- keep `update_plan`
- keep `view_image`
- `request_user_input` remains effectively unavailable for unattended `codex exec` flow

Shell execution must be deterministic and unambiguous:

- built-in shell disabled
- only MCP shell-equivalent tool available for command execution

## 10. Failure Model

For this iteration:

- no retries in MCP bridge
- no auto-start/auto-restart from MCP bridge
- failures are explicit and immediate

Mapping policy:

- keep existing public failure reason vocabulary
- map MCP startup failure, tool routing failure, and container exec failure classification to `runtime_error`
- include precise `failure_reason_detail` and `error_log` context

## 11. Required System Changes

1. Remove normal-path dependency on Codex bootstrap/copy into instance images.
2. Execute Codex on host and route shell commands through MCP bridge into runtime container.
3. Add deterministic runtime container naming and collision cleanup logic.
4. Add minimal MCP server script in repo.
5. Update `start-swebench.sh` Codex command construction to include per-run MCP `--config` overrides.
6. Keep `run-swebench-batch.sh` external behavior unchanged; only propagate internal changes through `start-swebench.sh`.
7. Update docs (`docs/implementation/phase5-runner.md` and index pages) to reflect new shell-routing architecture.
8. Update/extend tests for:
   - runtime container naming and collision cleanup behavior
   - no-bootstrap normal path
   - MCP config injection correctness
   - deterministic failure mapping and logs for MCP-path failures

## 12. Non-Goals (This Iteration)

1. Full container orchestration platform in MCP layer.
2. Parallel-execution redesign.
3. New failure reason code vocabulary.
4. Restrictive command allowlist/denylist policy.
5. Long-running MCP daemon architecture.

## 13. Expected End State

After implementation:

1. Codex is no longer copied into instance images for normal execution.
2. `start-swebench.sh` creates named runtime container, runs Codex on host, and routes shell commands into that container via MCP.
3. Shell path is deterministic (MCP-only), with fixed container/workdir binding per run.
4. Existing Phase 5 external contract remains intact aside from required internal shell-routing swap.
5. Diagnostics are clearer because container target and MCP routing are explicit in run logs.

## 14. Acceptance Criteria

1. Host-run Codex path is active; normal execution no longer depends on runtime image bootstrap of Codex.
2. Runtime container name follows `swebench-runtime-<sanitized-instance-id>` convention.
3. Runner force-removes same-name stale container before create.
4. Built-in Codex shell is disabled in runner invocation path.
5. Minimal MCP bridge is launched per run via stdio and marked required.
6. Bridge exposes only `mcp-docker-exec`.
7. Bridge executes commands only in prebound container/workdir.
8. Bridge returns exact exit code, stdout, stderr from `docker exec` path.
9. Existing Phase 5 output artifacts and status schema remain unchanged.
10. MCP-path failures map to existing `runtime_error` with explicit details.
11. `run-swebench-batch.sh` user-facing contract remains unchanged.
12. Docs and tests are updated to reflect and validate the new architecture.
