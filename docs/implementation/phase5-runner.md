# Phase 5 Runner Workflow

This page documents the implemented SWE-Bench prediction workflow for:

- `scripts/start-swebench.sh` (single-instance runner)
- `scripts/run-swebench-batch.sh` (sequential batch orchestrator)
- `scripts/prepare-swebench-codex-images.sh` (manual optional image prep helper)

Prediction and evaluation are intentionally separate. The Phase 5 runners produce prediction artifacts only; evaluation is run later via SWE-Bench harness tooling.

## Hard Runtime Contracts

- Codex-only execution path.
- Unattended execution path only.
- Fixed profile: `codex -p local`.
- Runtime prompts loaded only from:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
- Missing required prompt file is a hard-fail before instance execution.
- Runtime mutable state is written under per-instance output directories only (not under `.ralph/`).

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
   - `SPECIFICATION.md`
   - `EXECUTION_PLAN.md`
4. Validates image `sweb.eval.arm64.<instance_id>:latest`.
5. Ensures `codex` exists in image; attempts bootstrap fallback if missing.
6. Runs one `plan` pass.
7. Runs execute loop (`execute` then `handoff`) up to `--max-loops`.
8. Classifies terminal state and writes artifacts.
9. Writes/updates run manifest at `<manifest_dir>/run_manifest.json`.

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
  "failure_reason_code": "missing_image|codex_bootstrap_failed|blocked|incomplete|runtime_error|null",
  "failure_reason_detail": "<human readable detail>",
  "error_log": "<captured stderr/log excerpt>"
}
```

`failure_reason_code` vocabulary is fixed:

- `missing_image`
- `codex_bootstrap_failed`
- `blocked`
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

`start-swebench.sh` classifies using plan state + patch content:

- `success`:
  - `plans/archive/SPECIFICATION.md` exists
  - `plans/archive/EXECUTION_PLAN.md` exists
  - patch file is non-empty
- `failed`:
  - planning docs moved to `plans/blocked/`, or
  - precheck/runtime hard failure (missing image, bootstrap failure, runtime error)
- `incomplete`:
  - root planning docs remain when loop budget ends, or
  - archive exists with empty patch output

Blocked mode is terminal for that instance; no separate blocked prompt flow exists.

## Manual Image Prep Utility

`scripts/prepare-swebench-codex-images.sh` is manual and optional. It pre-injects codex into selected local images and commits changes back to the same image tags. Runtime scripts do not auto-call it.

See **[Prepare Codex Images](prepare-codex-images.md)** for selectors and examples.

## Evaluation Separation

Phase 5 runners only generate predictions (`.pred` files and aggregated `predictions.jsonl`). They do not run evaluation.

Run evaluation as a separate step (for example via `scripts/run_test_eval.sh` or direct `python -m swebench.harness.run_evaluation`).
