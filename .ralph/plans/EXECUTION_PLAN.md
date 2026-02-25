# Execution Plan: MCP-Routed Shell into Runtime Container

## 1. Objective
Implement `.ralph/plans/SPECIFICATION.md` by replacing in-container Codex execution/bootstrap with host-run Codex plus a deterministic MCP bridge that executes commands in the instance runtime container.

This plan preserves the frozen external Phase 5 contract from `.ralph/plans/archive/swe-ralph/SPECIFICATION.md` and `.ralph/plans/archive/swe-ralph/EXECUTION_PLAN.md` unless explicitly required by the shell-routing swap.

## 2. Current-State Audit Against Spec

Audit date: 2026-02-25

### 2.1 Acceptance Criteria Status

| Spec acceptance criterion | Status | Evidence |
| --- | --- | --- |
| 1. Host-run Codex path active; no normal-path image bootstrap dependency | Not met | Codex still runs via `docker exec`, but normal-path codex/bootstrap image mutation was removed from `scripts/start-swebench.sh` |
| 2. Runtime container uses `swebench-runtime-<sanitized-instance-id>` naming | Met | `scripts/start-swebench.sh` now computes deterministic `swebench-runtime-<sanitized-instance-id>` names |
| 3. Runner force-removes same-name stale container before create | Met | `scripts/start-swebench.sh` now does `docker rm -f <runtime_name>` before `docker create --name <runtime_name> ...` |
| 4. Built-in Codex shell disabled in runner invocation path | Not met | Codex invoked without shell disable overrides |
| 5. Minimal stdio MCP bridge launched per run and required | Not met | Repo-local bridge script exists, but `scripts/start-swebench.sh` does not launch/configure MCP yet |
| 6. Bridge exposes only `mcp-docker-exec` | Met | `scripts/mcp-docker-exec-server.py` exposes exactly one tool (`mcp-docker-exec`) via `tools/list` |
| 7. Bridge executes only in prebound container/workdir | Met | `scripts/mcp-docker-exec-server.py` requires startup bindings and always executes `docker exec -i -w <workdir> <container> /bin/sh -lc <command>` |
| 8. Bridge returns exact `exit_code`, `stdout`, `stderr` from `docker exec` path | Met | `scripts/mcp-docker-exec-server.py` returns raw `stdout`/`stderr` and exact exit code in structured payload |
| 9. Existing Phase 5 artifacts/status schema unchanged | Met | Current outputs and status/manifest schema already match Phase 5 contract |
| 10. MCP-path failures map to `runtime_error` with explicit details | Not met | No MCP path implemented yet |
| 11. `run-swebench-batch.sh` user-facing contract unchanged | Met | Current batch CLI/behavior already matches frozen contract |
| 12. Docs and tests updated for new architecture | Not met | Phase 2 bridge tests added (`tests/test_mcp_docker_exec_server.sh`), but runner MCP rewiring/failure mapping docs/tests remain pending |

### 2.2 Baseline Validation Snapshot

Current regression scripts pass (checkpoint after Phase 1 refactor):

- `bash tests/test_start_swebench.sh` -> PASS
- `bash tests/test_run_swebench_batch.sh` -> PASS
- `bash tests/test_prepare_swebench_codex_images.sh` -> PASS
- `bash tests/test_mcp_docker_exec_server.sh` -> PASS

### 2.3 Handoff Checkpoint (2026-02-25)

- Last implementation commit before this checkpoint: `1bd9bdd` (`main`, pushed to `origin/main`)
- Phase 1 status: complete (no-bootstrap normal path + deterministic runtime naming/collision cleanup)
- Phase 2 status: complete (stdlib MCP bridge server + fake-docker MCP protocol tests)
- Remaining plan work is tracked in beads:
  - `swebench-eval-next-6kd` (Phase 3 host-run Codex + MCP-only invocation rewiring)
  - `swebench-eval-next-p8m` (Phase 4/5 failure mapping + MCP-path tests/docs)
- Dependency chain in beads:
  - `swebench-eval-next-6kd` blocks `swebench-eval-next-p8m`
- Recommended pickup order:
  1. `swebench-eval-next-6kd`
  2. `swebench-eval-next-p8m`

## 3. Scope Guardrails

1. Preserve external runner contracts:
   - `scripts/start-swebench.sh` CLI/exit/status/artifacts/manifest semantics stay stable.
   - `scripts/run-swebench-batch.sh` user-facing behavior stays stable.
2. Keep failure reason vocabulary unchanged externally; classify new MCP-route failures as `runtime_error` with detailed `failure_reason_detail` and `error_log`.
3. Do not add MCP-driven lifecycle orchestration; runner still owns container create/start/cleanup.
4. Keep command freedom parity (no command allowlist/denylist in this iteration).

## 4. Implementation Plan

### Phase 1: Runner Refactor for Host-Run Codex + Deterministic Container Naming

Target files:

- `scripts/start-swebench.sh`

Tasks:

1. Remove normal-path codex bootstrap dependency from runtime flow:
   - remove image codex presence/config checks from invocation path.
   - remove normal-path calls to bootstrap functions.
   - keep `scripts/prepare-swebench-codex-images.sh` as manual utility only.
2. Add deterministic runtime container naming:
   - add helper to sanitize `instance_id` (lowercase, invalid chars -> `-`, collapse repeats, trim ends).
   - enforce deterministic max-length behavior for Docker name constraints.
   - final name format: `swebench-runtime-<sanitized-instance-id>`.
3. Add collision cleanup policy:
   - always run `docker rm -f <runtime_name>` before create (ignore not-found).
4. Create container using explicit `--name <runtime_name>` and keep existing trap-based cleanup ownership.

Definition of done:

- Runner creates named container deterministically and no longer requires codex-in-image bootstrap for normal execution.

Status (2026-02-25): Completed.

### Phase 2: Add Repo-Local MCP Bridge Server

Target files:

- `scripts/mcp-docker-exec-server.py` (new)

Tasks:

1. Implement minimal stdio MCP server in Python stdlib only.
2. Expose exactly one tool: `mcp-docker-exec`.
3. Require startup bindings (passed by runner/Codex config):
   - target runtime container name
   - fixed workdir
4. On tool call:
   - execute `/bin/sh -lc <command>` via `docker exec -i -w <workdir> <container> ...`
   - no TTY allocation
   - container default user (no `-u` override)
5. Return minimally framed response carrying:
   - `exit_code`
   - raw `stdout`
   - raw `stderr`
6. Return explicit error responses when bindings are missing or command input is invalid.

Definition of done:

- MCP bridge starts per run via stdio, provides only `mcp-docker-exec`, and returns exact command results.

Status (2026-02-25): Completed.

### Phase 3: Codex Invocation Rewire with Per-Run Config Overrides

Target files:

- `scripts/start-swebench.sh`

Tasks:

1. Change `run_codex_phase` to invoke Codex on host (not through `docker exec ... codex`).
2. Inject deterministic per-run overrides on each Codex call:
   - disable built-in shell tool.
   - register MCP server launcher (stdio command + args).
   - bind runtime container/workdir for that run via MCP server env/config.
3. Keep existing unattended/local-profile command contract:
   - `codex exec -p local --dangerously-bypass-approvals-and-sandbox ...`
4. Ensure no runtime mutation of `~/.codex/config.toml` and no temp config files.
5. Keep prompt rendering and plan/execute/handoff loop behavior unchanged.

Definition of done:

- Codex runs on host and shell operations are routed only through MCP bridge into the prebound runtime container.

### Phase 4: Failure Mapping and Diagnostics Hardening

Target files:

- `scripts/start-swebench.sh`

Tasks:

1. Map MCP startup/routing/container-exec failures to `failure_reason_code=runtime_error`.
2. Improve detail messages for MCP-path failures:
   - include phase/pass context
   - include runtime container name/workdir context
   - capture relevant stderr into `error_log`
3. Ensure existing public reason vocabulary remains unchanged.

Definition of done:

- MCP-path failures are explicit, diagnosable, and externally classified as `runtime_error`.

### Phase 5: Tests and Docs Update

Target files:

- `tests/test_start_swebench.sh`
- `tests/test_run_swebench_batch.sh` (confirm unchanged external contract)
- `docs/implementation/phase5-runner.md`
- `docs/README.md`
- `docs/implementation/README.md`
- `docs/project-status.md` (status wording update if needed)

Tasks:

1. Replace bootstrap-path assertions in start-runner tests with MCP-path assertions.
2. Add/extend tests for:
   - runtime container naming/sanitization and collision cleanup
   - no-bootstrap normal path
   - Codex config injection correctness (shell disabled + MCP server binding)
   - deterministic `runtime_error` mapping for MCP-path failures
3. Keep/confirm batch contract tests unchanged externally.
4. Update docs to describe new architecture:
   - host-run Codex + MCP shell routing into runtime container
   - runtime container naming/collision behavior
   - updated failure-mode notes
   - no normal-path dependency on codex-in-image bootstrap

Definition of done:

- Tests validate the new architecture and docs reflect implemented behavior.

## 5. Validation Matrix (Post-Implementation)

1. Static checks:
   - `bash -n scripts/start-swebench.sh scripts/run-swebench-batch.sh scripts/mcp-docker-exec-server.py scripts/prepare-swebench-codex-images.sh`
2. Functional tests:
   - `bash tests/test_start_swebench.sh`
   - `bash tests/test_run_swebench_batch.sh`
   - `bash tests/test_prepare_swebench_codex_images.sh`
3. Contract checks:
   - per-instance artifacts/status schema unchanged
   - manifest schema/count logic unchanged
   - batch CLI and run-root behavior unchanged
4. New architecture checks:
   - Codex no longer executed via `docker exec ... codex`
   - shell tool disabled in codex invocation
   - MCP bridge tool surface limited to `mcp-docker-exec`
   - runtime container name deterministic and collision cleanup enforced
   - MCP-path failures map to `runtime_error` with explicit details

## 6. Risks and Mitigations

1. Risk: Codex `--config` quoting for nested arrays/tables may be brittle in shell.
   - Mitigation: centralize config-arg construction in helper functions and add tests that assert emitted command arguments.
2. Risk: MCP protocol implementation errors in stdlib-only server.
   - Mitigation: keep tool surface minimal, add deterministic unit-like script tests with fake docker behavior.
3. Risk: Docker name-length behavior mismatch.
   - Mitigation: codify one deterministic truncation strategy and test with pathological instance IDs.

## 7. Sequencing

1. Phase 1 runner refactor (container naming + remove normal bootstrap path dependency)
2. Phase 2 MCP bridge implementation
3. Phase 3 codex invocation rewiring
4. Phase 4 failure mapping hardening
5. Phase 5 tests/docs updates
6. Validation matrix run
7. Final acceptance review against all 12 spec criteria

Current sequencing state:

1. Phase 1 complete
2. Phase 2 complete
3. Next active target: Phase 3 (`swebench-eval-next-6kd`)
