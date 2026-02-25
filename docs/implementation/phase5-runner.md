# Phase 5 Runner Workflow

This page documents the implemented SWE-Bench prediction workflow for:

- `scripts/start-swebench.sh` (single-instance runner)
- `scripts/run-swebench-batch.sh` (sequential batch orchestrator)
- `scripts/prepare-swebench-codex-images.sh` (manual optional image prep helper)

Prediction and evaluation are intentionally separate. The Phase 5 runners produce prediction artifacts only; evaluation is run later via SWE-Bench harness tooling.

## Execution Status

As of **February 23, 2026**:

- Phase 5 script implementation is complete.
- Plan-defined validation was completed (script/contract validation recorded in `.ralph/plans/archive/swe-ralph/EXECUTION_PLAN.md`).
- One live SWE-Bench evaluation replay was completed for `google__gson-2024` using a Phase 5-produced prediction, and it resolved after eval namespace/image fixes.
- A full benchmark-scale Phase 5 run has not yet been executed.

For top-level status context across phases, see **[Project Status](../project-status.md)**.

## Hard Runtime Contracts

- Codex-only execution path.
- Unattended execution path only.
- Fixed profile: `codex -p local`.
- `codex -p local` must resolve to local DGX provider (LiteLLM on `:8000` + vLLM on `:8888`).
- Codex phase commands are invoked on host.
- Built-in shell execution is disabled per invocation (`features.shell_tool=false`, `features.unified_exec=false`).
- A per-run stdio MCP bridge (`scripts/mcp-docker-exec-server.py`) is injected per Codex call and bound to:
  - runtime container `swebench-runtime-<sanitized-instance-id>`
  - fixed container workdir (default `/testbed`)
- Shell command execution is routed into the runtime container through MCP tool `mcp-docker-exec`.
- Runtime prompts loaded only from:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
- Prompt template variables are rendered by `start-swebench.sh` before each Codex call.
  - Supported forms: `{{VAR}}`, `${VAR}`, and `$VAR`
  - Supported vars: `SWE_BENCH_RUNTIME_PHASE`, `SWE_BENCH_EXECUTE_PASS`, `SWE_BENCH_INSTANCE_ID`, `SWE_BENCH_OUTPUT_DIR`, `SWE_BENCH_PLANS_DIR`, `SWE_BENCH_SPEC_PATH`, `SWE_BENCH_PLAN_PATH`, `SWE_BENCH_ARCHIVE_DIR`, `SWE_BENCH_BLOCKED_DIR`, `SWE_BENCH_PATCH_PATH`, `SWE_BENCH_IMAGE_REF`
- Missing required prompt file is a hard-fail before instance execution.
- Runtime mutable state is written under per-instance output directories only (not under `.ralph/`).

For concrete startup and validation commands, see **[Codex Local Bridge](codex-local-bridge.md)**.

Minimum preflight before batch launch:

```bash
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

- Required:
  - `--instance-id`
  - `--output-dir`
- Optional:
  - `--manifest-dir` (defaults to `--output-dir` when omitted)
  - `--max-loops` (default: `50`, positive integer)

### Behavior

For one invocation, the script:

1. Validates runtime prompts under `ralph/prompts/`.
2. Loads instance `problem_statement` from:
   - default dataset `SWE-bench/SWE-bench_Multilingual` (`multilingual`, `test`), or
   - `SWE_BENCH_INSTANCES_FILE` fixture override (`.json` or `.jsonl`).
3. Seeds planning docs under `<output_dir>/plans/`:
   - `SPECIFICATION.md` only (contains only `## Problem Statement` from instance metadata)
4. Validates image `sweb.eval.arm64.<instance_id>:latest`.
5. Creates a deterministic runtime container name:
   - `swebench-runtime-<sanitized-instance-id>`
   - sanitization: lowercase, chars outside `[a-z0-9_.-]` replaced with `-`, repeated `-` collapsed, edge `-` trimmed, deterministic truncation to Docker-safe length
   - stale same-name container is force-removed before create (`docker rm -f <name>`, ignore not-found)
6. Creates/starts the runtime container from the instance image; Codex runs on host with shell routed into that container via MCP bridge.
7. Enters loop-based phase dispatch:
   - if root `SPECIFICATION.md` exists and root `EXECUTION_PLAN.md` is missing: run `plan` as its own Codex session (`codex exec`, no resume).
   - if both root planning docs exist: run `execute` as a new Codex session (`codex exec`, no resume).
8. After each `execute` pass:
   - if patch file is non-empty: classify `success` and exit.
   - if patch is empty and both root planning docs remain: run `handoff` by resuming that execute session (`codex exec resume <execute_session_id>`), then continue loop.
   - if patch is empty and root planning docs are not both present: classify `failed` (`runtime_error`) and exit.
9. Stops at `--max-loops` execute-pass budget if no terminal state was reached and classifies `incomplete`.
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

- `<instance_id>.patch`
- `<instance_id>.pred`
- `<instance_id>.status.json`

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
  - MCP-routed plan/execute/handoff command failures remain `runtime_error` and include explicit context in `failure_reason_detail`:
    - `phase`, `pass`, `runtime_container`, `workdir`, `mcp_server`
    - `error_log` includes any immediate phase stderr plus a tail excerpt from `logs/codex_<phase>.log`
- `incomplete`:
  - root planning docs remain and execute-pass budget is exhausted without a patch

## Manual Image Prep Utility

`scripts/prepare-swebench-codex-images.sh` is manual and optional. It pre-injects codex into selected local images and commits changes back to the same image tags while preserving original `ENTRYPOINT`/`CMD`. Runtime scripts do not auto-call it.

See **[Prepare Codex Images](prepare-codex-images.md)** for selectors and examples.

## Evaluation Separation

Phase 5 runners only generate predictions (`.pred` files and aggregated `predictions.jsonl`). They do not run evaluation.

Run evaluation as a separate step (for example via `scripts/run_test_eval.sh` or direct `python -m swebench.harness.run_evaluation`). Use `--namespace none` for ARM64 local-image evaluation so harness selection stays on local `sweb.eval.arm64.*` images rather than stale shared `swebench/...` tags.

Important: `run_evaluation` writes its summary report to the current working directory unless `--report_dir` is set. For manual Phase 5 eval runs, always set `--report_dir` (or `cd` into a run folder first) to avoid cluttering repo root with `qwen3-coder-next-FP8,codex,ralph.phase5-*.json` files.

Example:

```bash
python -m swebench.harness.run_evaluation \
  --dataset_name SWE-bench/SWE-bench_Multilingual \
  --predictions_path results/phase5/ralph-codex-local/<run_ts>/predictions.jsonl \
  --run_id phase5-<label> \
  --arch arm64 \
  --namespace none \
  --report_dir results/phase5/ralph-codex-local/<run_ts>/eval
```
