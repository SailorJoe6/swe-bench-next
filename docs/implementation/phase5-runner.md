# Phase 5 Runner (Current State)

This document describes the current implementation state of the active SWE-Bench Phase 5 runners.

## Scripts

- `scripts/start-swebench.sh` (single-instance runner)
- `scripts/run-swebench-batch.sh` (batch orchestrator)

## Single-Instance Scope Implemented

`scripts/start-swebench.sh` implements the full **Phase 2 single-instance runtime core**:

- Requires `--instance-id <id>`.
- Requires `--output-dir <path>`.
- Supports optional `--manifest-dir <path>` (defaults to `--output-dir`).
- Supports `--max-loops <n>` (default: `50`; positive integer validation).
- Enforces Codex-only local profile contract with `codex -p local --dangerously-bypass-approvals-and-sandbox exec`.
- Performs runtime prompt preflight for:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
- Loads instance metadata and `problem_statement` from:
  - default dataset `SWE-bench/SWE-bench_Multilingual` (`multilingual`, `test`)
  - optional fixture override `SWE_BENCH_INSTANCES_FILE=<json|jsonl>`
- Seeds per-instance planning docs under `--output-dir/plans/`:
  - `SPECIFICATION.md`
  - `EXECUTION_PLAN.md`
- Performs image/bootstrap prechecks:
  - validates `sweb.eval.arm64.<instance_id>:latest`
  - checks codex inside image and attempts bootstrap fallback
- Executes runtime phases:
  - one `plan` pass
  - execute loop (`execute` then `handoff`) up to `--max-loops`
- Classifies final state using per-instance plan locations:
  - `plans/archive/` with non-empty patch => `success`
  - `plans/blocked/` => `failed` with `failure_reason_code: "blocked"`
  - root plans after budget => `incomplete` with `failure_reason_code: "incomplete"`
- Writes required per-instance artifacts:
  - `<instance>.patch`
  - `<instance>.pred`
  - `<instance>.status.json`
- Writes/updates run-level manifest:
  - `<manifest_dir>/run_manifest.json`

### Exit Semantics

- `0` when status is `success`.
- `1` when status is `failed`.
- `20` when status is `incomplete`.

### Failure Reason Mapping

- Prompt/metadata/codex runtime failures => `runtime_error`
- Missing image => `missing_image`
- Codex bootstrap failure => `codex_bootstrap_failed`
- Blocked terminal state => `blocked`
- Loop budget exhaustion/non-terminal end state => `incomplete`
- Success => `null`

### Usage

```bash
scripts/start-swebench.sh \
  --instance-id <instance_id> \
  --output-dir <path> \
  [--manifest-dir <path>] \
  [--max-loops 50]
```

## Batch Scope Implemented

`scripts/run-swebench-batch.sh` now implements **Phase 3 orchestration**:

- Resolves instance IDs from:
  - default scope (`SWE-bench/SWE-bench_Multilingual`, `multilingual`, `test`), or
  - optional `--instance-file <path>` subset.
- Sorts resolved IDs lexicographically by `instance_id`.
- Creates one timestamped run root:
  - `results/phase5/ralph-codex-local/<timestamp>/`
- Invokes `scripts/start-swebench.sh` sequentially per instance with:
  - `--output-dir <run_root>/<instance_id>`
  - `--manifest-dir <run_root>`
  - `--max-loops <n>` (default 50, overridable on batch script)
- Continues processing after per-instance failures.
- Builds run-level `predictions.jsonl` by aggregating `<run_root>/<instance_id>/<instance_id>.pred`.
- Leaves run-level manifest ownership to `scripts/start-swebench.sh`.

### Batch Usage

```bash
scripts/run-swebench-batch.sh [--instance-file <path>] [--max-loops 50]
```

## Notes

Remaining plan work is now outside `start-swebench.sh`:

- `scripts/prepare-swebench-codex-images.sh` (Phase 4 manual prep utility)
- Top-level workflow docs end-state (Phase 5)
