# Phase 5 Runner Workflow

This page documents the implemented SWE-Bench prediction workflow for:

- `scripts/start-swebench.sh` (single-instance runner)
- `scripts/run-swebench-batch.sh` (sequential batch orchestrator)
- `scripts/prepare-swebench-codex-images.sh` (manual optional image prep helper)

Prediction and evaluation are intentionally separate. The Phase 5 runners produce prediction artifacts only; evaluation is run later via SWE-Bench harness tooling.

## Execution Status

As of **February 25, 2026**:

- Phase 5 script implementation and MCP-routed architecture closeout are complete.
- Plan-defined validation is complete (`tests/test_start_swebench.sh`, `tests/test_run_swebench_batch.sh`, `tests/test_mcp_docker_exec_server.sh`).
- One live SWE-Bench evaluation replay was completed for `google__gson-2024` using a Phase 5-produced prediction, and it resolved after eval namespace/image fixes.
- A live single-instance integration run was executed for a known Phase 3 error ID (`preactjs__preact-2896`) to validate runner behavior on a previously failing instance.
- MCP startup-timeout in that integration run was fixed (bridge transport compatibility bug; now supports line-delimited and `Content-Length` stdio JSON-RPC).
- Metadata loading has been aligned with the Phase 3 multilingual source contract and now resolves multilingual subset loading through `swe-bench/SWE-Bench_Multilingual` (split-only load).
- A full benchmark-scale Phase 5 run has not yet been executed.

For top-level status context across phases, see **[Project Status](../project-status.md)**.

## Hard Runtime Contracts

- Codex-only execution path.
- Unattended execution path only.
- Fixed profile: `codex -p local`.
- Fixed config home: `CODEX_HOME=config/codex-home` (override via `SWE_BENCH_CODEX_HOME`).
- `codex -p local` must resolve to local DGX provider (LiteLLM on `:8000` + vLLM on `:8888`).
- `config/codex-home/config.toml` binds `profiles.local.model_instructions_file` to `config/codex-home/prompt.md` (repo-local authoritative base instructions).
- The repo-local base instructions explicitly require MCP-only command/edit/patch flow via `swebench_docker_exec.mcp-docker-exec({"command":"..."})` and explicitly forbid `apply_patch`.
- Codex phase commands are invoked on host.
- Built-in shell execution is disabled per invocation (`features.shell_tool=false`, `features.unified_exec=false`).
- A per-run stdio MCP bridge (`scripts/mcp-docker-exec-server.py`) is injected per Codex call and bound to:
  - runtime container `swebench-runtime-<sanitized-instance-id>`
  - fixed container workdir (default `/testbed`)
- Shell command execution is routed into the runtime container through MCP tool `mcp-docker-exec`.
- MCP bridge enforces a per-command timeout to avoid deadlocks from long-running shell commands:
  - default `55s`
  - configurable via `SWE_BENCH_MCP_DOCKER_EXEC_TIMEOUT_SECONDS`
  - timeout returns tool payload `exit_code=124` (stderr includes timeout detail)
- MCP bridge transport compatibility is required for Codex startup in this environment:
  - newline-delimited JSON-RPC
  - `Content-Length` framed JSON-RPC
- Runtime prompts loaded only from:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
- Prompt template variables are rendered by `start-swebench.sh` before each Codex call.
  - Supported forms: `{{VAR}}`, `${VAR}`, and `$VAR`
  - Supported vars: `SWE_BENCH_RUNTIME_PHASE`, `SWE_BENCH_EXECUTE_PASS`, `SWE_BENCH_INSTANCE_ID`, `SWE_BENCH_OUTPUT_DIR`, `SWE_BENCH_PLANS_DIR`, `SWE_BENCH_SPEC_PATH`, `SWE_BENCH_PLAN_PATH`, `SWE_BENCH_ARCHIVE_DIR`, `SWE_BENCH_BLOCKED_DIR`, `SWE_BENCH_PATCH_PATH`, `SWE_BENCH_IMAGE_REF`
  - Path vars are rendered as host-absolute output paths so they match Codex host workdir expectations.
  - `SWE_BENCH_PATCH_PATH` points to a per-run staging path (hidden `*.patch.tmp`), and the final `<instance_id>.patch` artifact is only published when staging content is non-empty.
- Missing required prompt file is a hard-fail before instance execution.
- Runtime mutable state is written under per-instance output directories only (not under `.ralph/`).

For concrete startup and validation commands, see **[Codex Local Bridge](codex-local-bridge.md)**.

Minimum preflight before batch launch:

```bash
CODEX_HOME="$(pwd)/config/codex-home" \
codex exec -p local --dangerously-bypass-approvals-and-sandbox \
  "Respond with exactly: CODEX_LOCAL_BRIDGE_OK"
```

## Single-Instance Runner: `start-swebench.sh`

### CLI

```bash
scripts/start-swebench.sh \
  --instance-id <instance_id> \
  --output-dir <path> \
  [--manifest-dir <path>] \
  [--max-loops 50]
```

### Launch Policy (Required)

Always launch single-instance runs detached with `nohup` so terminal/session loss does not terminate the active phase loop.

```bash
nohup scripts/start-swebench.sh \
  --instance-id <instance_id> \
  --output-dir <path> \
  [--manifest-dir <path>] \
  [--max-loops 50] \
  > <path>/logs/start-swebench.nohup.log 2>&1 &
```

AI-agent environment caveat:
- Some managed agent runtimes reap background children started from one-shot command executions, even when launched with `nohup`.
- Symptom pattern: process exits within a few seconds, `start-swebench.nohup.log` remains empty or near-empty, and no `*.status.json`/`run_manifest.json` is written.
- In those environments, launch detached via `tmux` instead of direct `nohup`.

Example (`tmux` fallback):

```bash
tmux new-session -d -s swebench_single_<instance_id> '
  cd /abs/path/to/swebench-eval-next &&
  OUT=<path> &&
  mkdir -p "$OUT/logs" &&
  scripts/start-swebench.sh \
    --instance-id <instance_id> \
    --output-dir "$OUT" \
    [--manifest-dir <path>] \
    [--max-loops 50] \
    > "$OUT/logs/start-swebench.nohup.log" 2>&1
'
```

Useful `tmux` checks:

```bash
tmux ls
tmux capture-pane -pt swebench_single_<instance_id>
```

- Required:
  - `--instance-id`
  - `--output-dir`
- Optional:
  - `--manifest-dir` (defaults to `--output-dir` when omitted)
  - `--max-loops` (default: `50`, positive integer)
  - `SWE_BENCH_CODEX_PHASE_TIMEOUT_SECONDS` env var (default: `1800`) to cap each Codex phase runtime and prevent long hangs

### Behavior

For one invocation, the script:

1. Validates runtime prompts under `ralph/prompts/`.
2. Loads instance `problem_statement` from:
   - default multilingual scope (`multilingual`, `test`) resolved to Phase 3-compatible dataset path `swe-bench/SWE-Bench_Multilingual`, or
   - `SWE_BENCH_INSTANCES_FILE` fixture override (`.json` or `.jsonl`).
   - metadata loading and artifact JSON writes use `SWE_BENCH_PYTHON_BIN` if set, otherwise repo `venv/bin/python3` when available, otherwise `python3`.
3. Seeds planning docs under `<output_dir>/plans/`:
   - `SPECIFICATION.md` only (contains only `## Problem Statement` from instance metadata)
4. Validates image `sweb.eval.arm64.<instance_id>:latest`.
5. Creates a deterministic runtime container name:
   - `swebench-runtime-<sanitized-instance-id>`
   - sanitization: lowercase, chars outside `[a-z0-9_.-]` replaced with `-`, repeated `-` collapsed, edge `-` trimmed, deterministic truncation to Docker-safe length
   - stale same-name container is force-removed before create (`docker rm -f <name>`, ignore not-found)
6. Creates/starts the runtime container from the instance image; Codex runs on host with shell routed into that container via MCP bridge.
   - bind mount: host `--output-dir` -> same absolute path inside container
7. Enters loop-based phase dispatch:
   - if root `SPECIFICATION.md` exists and root `EXECUTION_PLAN.md` is missing: run `plan` as its own Codex session (`codex exec`, no resume), then re-evaluate state on the next loop pass.
   - if both root planning docs exist: run `execute` as a new Codex session (`codex exec`, no resume).
8. After each `execute` pass:
   - if patch file is non-empty: classify `success` and exit.
   - if patch is empty and both root planning docs remain: run `handoff` by resuming that execute session (`codex exec resume <execute_session_id>`), then continue loop.
   - if patch is empty and root planning docs are not both present: classify `failed` (`runtime_error`) and exit.
   - non-zero `codex` exits in `plan`/`execute`/`handoff` are logged to `logs/runtime_warning.log` and the runner continues until success or loop budget exhaustion.
9. Stops at `--max-loops` budget if no terminal state was reached:
   - `incomplete` when plan budget is exhausted while still in `spec_only`
   - `incomplete` when execute budget is exhausted while root planning docs remain
10. Writes artifacts and updates run manifest at `<manifest_dir>/run_manifest.json`.

### Exit Codes

- `0` for `status=success`
- `1` for `status=failed`
- `20` for `status=incomplete`

## Batch Orchestrator: `run-swebench-batch.sh`

### CLI

```bash
scripts/run-swebench-batch.sh \
  [--instance-file <path>] \
  [--max-loops 50]
```

### Launch Policy (Required)

Always launch batch runs detached with `nohup`.

```bash
nohup scripts/run-swebench-batch.sh \
  [--instance-file <path>] \
  [--max-loops 50] \
  > results/phase5/run-swebench-batch.nohup.log 2>&1 &
```

Important: apply `nohup` to the batch orchestrator process itself only. Do not modify batch logic to wrap each per-instance `start-swebench.sh` call in `nohup`.

AI-agent environment caveat:
- If your execution environment reaps `nohup` jobs started from one-shot commands, launch batch via detached `tmux`.

Example (`tmux` fallback):

```bash
tmux new-session -d -s swebench_batch '
  cd /abs/path/to/swebench-eval-next &&
  scripts/run-swebench-batch.sh \
    [--instance-file <path>] \
    [--max-loops 50] \
    > results/phase5/run-swebench-batch.nohup.log 2>&1
'
```

### Behavior

- Resolves scope from either:
  - default `SWE-bench/SWE-bench_Multilingual` (`multilingual`, `test`), or
  - `--instance-file` subset input (`txt`, `json`, or `jsonl`).
- Sorts `instance_id` values lexicographically.
- Creates one run root:
  - `results/phase5/ralph-codex-local/<timestamp>/`
- Invokes `start-swebench.sh` once per instance, sequentially, with:
  - `--output-dir <run_root>/<instance_id>`
  - `--manifest-dir <run_root>`
  - `--max-loops <n>`
- Continues after per-instance failures.
- Aggregates per-instance `<instance>.pred` files into:
  - `<run_root>/predictions.jsonl`
- Does not own manifest creation (manifest is written by `start-swebench.sh`).

Batch process exit:

- `0` when all instances are `success`
- `1` when one or more instances are `failed`
- `20` when none failed but one or more are `incomplete`

## Output Contract

### Per-Instance Artifacts

Written under `<run_root>/<instance_id>/` (or directly under `--output-dir` for standalone runs):

- `<instance_id>.pred`
- `<instance_id>.status.json`
- `<instance_id>.patch` (success only; not created for failed/incomplete runs)
- `logs/codex_run.log` (single Codex phase log for plan/execute/handoff)

`logs/codex_run.log` section headers:

- `Loop #N - Plan Mode`
- `Loop #N - Execute Mode`
- `Handoff` (no loop number)

`<instance_id>.pred` schema:

```json
{
  "model_name_or_path": "qwen3-coder-next-FP8,codex,ralph",
  "instance_id": "<instance_id>",
  "model_patch": "<patch or empty string>"
}
```

`<instance_id>.status.json` schema:

```json
{
  "instance_id": "<instance_id>",
  "status": "success|failed|incomplete",
  "failure_reason_code": "missing_image|incomplete|runtime_error|null",
  "failure_reason_detail": "<human readable detail>",
  "error_log": "<captured stderr/log excerpt>"
}
```

`failure_reason_code` vocabulary is fixed:

- `missing_image`
- `incomplete`
- `runtime_error`
- `null` (success only)

### Run-Level Artifacts

Under `<run_root>/`:

- `run_manifest.json`
- `predictions.jsonl` (batch script only)
- `run_swebench_batch.log`
- `instance_order.txt`

`run_manifest.json` includes:

- invocation args (`instance_id`, `output_dir`, `manifest_dir`, `max_loops`)
- dataset scope (`name`, `subset`, `split`)
- codex settings (`profile=local`, unattended flag)
- `created_at` and `updated_at`
- per-instance status records with:
  - `status`
  - `failure_reason_code`
  - `failure_reason_detail`
  - `error_log`
  - `output_dir`
  - per-instance start/end time
- aggregate counts (`total`, `success`, `failed`, `incomplete`)

## Classification Rules

`start-swebench.sh` classifies from execute-loop outcomes:

- `success`:
  - patch file is non-empty after an execute pass
- `failed`:
  - precheck/runtime hard failure (missing image or runtime error), or
  - execute finished without patch and root planning docs are no longer both present (mismatch state)
- `incomplete`:
  - plan budget is exhausted while still in `spec_only`, or
  - root planning docs remain and execute-pass budget is exhausted without a patch
  - non-zero `codex` phase exits can contribute warning context in `error_log` from `logs/runtime_warning.log` without forcing immediate `failed` status.

## Manual Image Prep Utility

`scripts/prepare-swebench-codex-images.sh` is manual and optional. It pre-injects codex into selected local images and commits changes back to the same image tags while preserving original `ENTRYPOINT`/`CMD`. Runtime scripts do not auto-call it.

See **[Prepare Codex Images](prepare-codex-images.md)** for selectors and examples.

## Evaluation Separation

Phase 5 runners only generate predictions (`.pred` files and aggregated `predictions.jsonl`). They do not run evaluation.

Run evaluation as a separate step (for example via `scripts/run_test_eval.sh` or direct `python -m swebench.harness.run_evaluation`). Use `--namespace none` for ARM64 local-image evaluation so harness selection stays on local `sweb.eval.arm64.*` images rather than stale shared `swebench/...` tags.

Important: `run_evaluation` summary JSON artifacts may land in the current working directory even when `--report_dir` is set (observed in this project runtime). For manual Phase 5 eval runs, run from a dedicated output directory (for example `<campaign_root>/evaluations`) to avoid cluttering repo root with `qwen3-coder-next-FP8,codex,ralph.phase5-*.json` files.

Example:

```bash
mkdir -p results/phase5/ralph-codex-local/<run_ts>/evaluations
(
  cd results/phase5/ralph-codex-local/<run_ts>/evaluations
  python -m swebench.harness.run_evaluation \
    --dataset_name SWE-bench/SWE-bench_Multilingual \
    --predictions_path ../predictions.jsonl \
    --run_id phase5-<label> \
    --arch arm64 \
    --namespace none \
    --report_dir ../eval
)
```
