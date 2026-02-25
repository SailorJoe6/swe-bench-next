# Specification: SWE-Bench Predictions via Simplified Ralph + Codex Local Profile

## 1. Objective
Build a SWE-Bench prediction workflow around a simplified, SWE-Bench-specific Ralph loop using Codex CLI with the DGX Spark local endpoint (`codex -p local`).

The workflow must be split into:
- a single-instance runner, and
- a batch orchestrator that loops over the single-instance runner.

This separation reduces complexity, improves testability, and keeps batch orchestration concerns separate from per-instance execution concerns.

## 2. Current System

### 2.1 Existing Evaluation Pipeline
The project currently supports SWE-Bench Multilingual runs using SWE-Agent and ARM64-native instance images.

Current scripts:
- `scripts/run_predictions.sh` runs SWE-Agent batch predictions.
- `scripts/run_test_eval.sh` runs SWE-Bench evaluation separately.

### 2.2 Existing Ralph Tooling
`ralph/start` is a general-purpose workflow tool that is broader than needed for this project. For SWE-Bench we need a narrower, deterministic flow with explicit per-instance state.

### 2.3 Directory Role Boundaries (Critical)
- `ralph/` is reference + static assets:
  - full-power Ralph implementation/docs are reference only,
  - `ralph/prompts` hosts final static SWE-Bench runtime prompts.
- `.ralph/` is planning/status only:
  - in-progress spec/plan documents live here,
  - `.ralph/` is never runtime state.
- Finished runtime behavior is implemented through:
  - scripts in `scripts/`,
  - runtime outputs in `results/phase5/...`.

## 3. Required System Changes

### 3.1 New Entry Points
Add three scripts:
- `scripts/start-swebench.sh` (single-instance runner)
- `scripts/run-swebench-batch.sh` (batch orchestrator)
- `scripts/prepare-swebench-codex-images.sh` (manual optional prep utility)

### 3.2 Scope and Responsibility Split
- `start-swebench.sh` responsibilities:
  - run exactly one instance (`--instance-id` required),
  - require explicit output destination (`--output-dir <path>`) for that instance,
  - accept optional `--manifest-dir <path>` (defaults to `--output-dir` when omitted),
  - perform per-instance spec-seed -> plan -> execute -> handoff flow,
  - handle container checks/bootstrap,
  - classify result and write per-instance artifacts (`.patch`, `.pred`, `.status.json`),
  - write/update run-level `run_manifest.json`.
- `run-swebench-batch.sh` responsibilities:
  - resolve batch scope (default split and optional instance-file subset),
  - sort instances lexicographically by `instance_id`,
  - call `start-swebench.sh` once per instance (sequential),
  - pass `--manifest-dir` as parent of instance `--output-dir`,
  - continue after per-instance failures,
  - build run-level `predictions.jsonl` (and optional derived counters) by reading per-instance outputs.
- Evaluation remains separate from both scripts.

### 3.3 Model/Tool Constraints (Hard Requirements)
For both runner layers:
- Codex only (no Claude path).
- Unattended execution only.
- Force `codex -p local` (no profile override option).

### 3.4 Data Source and Run Modes
- `start-swebench.sh`:
  - single-instance mode only, via required `--instance-id <id>`,
  - required `--output-dir <path>` for per-instance runtime outputs,
  - optional `--manifest-dir <path>` (defaults to `--output-dir`).
- `run-swebench-batch.sh`:
  - default scope: SWE-Bench Multilingual, test split,
  - optional `--instance-file` subset input,
  - sequential only,
  - deterministic lexicographic ordering by `instance_id`.

### 3.5 Container/Image Strategy
Use local SWE-Bench ARM64 instance images (`sweb.eval.arm64.<instance>:latest`) as execution containers.

Codex availability:
- Runtime fallback in `start-swebench.sh`:
  - check for codex in container,
  - bootstrap if missing.
- Manual prep path in `scripts/prepare-swebench-codex-images.sh`:
  - pre-inject codex binary/config,
  - overwrite image tags in place,
  - not auto-invoked by runtime scripts.

### 3.6 Codex Binary and Config Injection
Bootstrap sources:
- binary: `/home/sailorjoe6/.cargo/bin/codex`
- config: `/home/sailorjoe6/.codex/config.toml`

The `local` profile must remain usable inside container context.

### 3.7 Ralph Workflow Adaptation for SWE-Bench
Per-instance flow in `start-swebench.sh`:
- seed `SPECIFICATION.md` from `problem_statement` (no design prompt phase),
- run `plan.md`,
- run execute loop via `execute.md`,
- run `handoff.md` on execute passes,
- terminal blocked state means failed instance; no blocked-mode prompt flow.

Runtime prompt set (only):
- `ralph/prompts/plan.md`
- `ralph/prompts/execute.md`
- `ralph/prompts/handoff.md`

`design.md` and `blocked.md` are not runtime inputs.

Prompt preflight:
- Required prompt files must be validated before first instance execution.
- Missing required prompt file is a hard-fail for the invocation.

### 3.8 Loop Termination and Pass Budget
- `--max-loops` applies to execute-phase iterations only.
- Default is `50`.
- Terminal state detection uses per-instance plan directories (`archive`, `blocked`, root).

### 3.9 Per-Instance Isolation and Paths
Per-instance mutable runtime state includes at minimum:
- plans (`SPECIFICATION.md`, `EXECUTION_PLAN.md`)
- plans state folders (`archive/`, `blocked/`)
- per-instance logs and artifacts

Location policy:
- runtime state must be under per-instance output folders in `results/phase5/...`.
- runtime state must not be written under `.ralph/`.
- `ralph/` may host static prompts only.

### 3.10 Classification and Failure Reasons
Per-instance status values are fixed:
- `success`
- `failed`
- `incomplete`

Classification rules:
- `success`: planning docs archived and non-empty patch.
- `failed`: planning docs moved to blocked.
- `incomplete`: planning docs remain in root plans dir when run ends.

Failure reason code vocabulary (fixed):
- `missing_image`
- `codex_bootstrap_failed`
- `blocked`
- `incomplete`
- `runtime_error`
- `null` (success only)

### 3.11 Artifact Contract
Per instance, write:
- `<instance>.patch`
- `<instance>.pred` with keys:
  - `model_name_or_path` (must be `qwen3-coder-next-FP8,codex,ralph`)
  - `instance_id`
  - `model_patch`
- `<instance>.status.json` with keys:
  - `instance_id`
  - `status`
  - `failure_reason_code`
  - `failure_reason_detail`
  - `error_log`

`<instance>.status.json` must always be written for every processed instance, including success.

For blocked/failed/no-image/bootstrap-fail cases, `model_patch` must be explicit empty string.

### 3.12 Batch-Level Outputs
`run-swebench-batch.sh` must produce:
- run root: `results/phase5/ralph-codex-local/<timestamp>/`
- run-level `predictions.jsonl` (constructed by aggregating `<instance>.pred` files)

Run-level manifest ownership:
- `start-swebench.sh` writes/updates `run_manifest.json`.
- Manifest path is `<manifest_dir>/run_manifest.json`.
- If `--manifest-dir` is omitted, `manifest_dir` defaults to `--output-dir`.
- In batch mode (with `--output-dir <run_root>/<instance_id>` and `--manifest-dir <run_root>`), this resolves to:
  - `results/phase5/ralph-codex-local/<timestamp>/run_manifest.json`
- `start-swebench.sh` must always write/update `run_manifest.json` for every invocation, including direct single-instance runs.

Manifest must include:
- invocation args
- dataset/scope
- start/end times
- per-instance status and failure metadata (`status`, `failure_reason_code`, `failure_reason_detail`, `error_log`)
- aggregate counts

Batch error policy:
- continue processing remaining instances after per-instance failures.
- `run-swebench-batch.sh` should create one timestamped run root and pass per-instance `--output-dir` paths under that run root to each `start-swebench.sh` invocation.
- `run-swebench-batch.sh` should pass `--manifest-dir <run_root>` on each `start-swebench.sh` invocation.
- Per-instance output path convention is fixed: `--output-dir <run_root>/<instance_id>`.

### 3.13 Documentation End-State
Top-level `docs/` must document the finished workflow and entrypoints:
- `scripts/start-swebench.sh` (single-instance)
- `scripts/run-swebench-batch.sh` (batch)

`ralph/docs` must not be the canonical source for the finished workflow.

## 4. Out of Scope
- Running evaluation from prediction scripts.
- Supporting Claude or non-local profiles.
- Parallel batch execution (>1 worker).
- Runtime mutable state under `.ralph/`.

## 5. Expected End State
After implementation:
- Operators can run one instance with `scripts/start-swebench.sh --instance-id <id> --output-dir <path> [--manifest-dir <path>]`.
- Operators can run sequential batch predictions with `scripts/run-swebench-batch.sh`.
- Batch order is deterministic (lexicographic by `instance_id`).
- Per-instance outputs are isolated under `results/phase5/.../<instance>/`.
- Batch run outputs include `predictions.jsonl` and `run_manifest.json`.
- Failure reasons are machine-readable in both per-instance status files and batch manifest.
- `.ralph/` remains planning-only.
- `ralph/prompts` contains final runtime prompts.

## 6. Acceptance Criteria
1. `scripts/start-swebench.sh` exists, runs exactly one instance per invocation, requires `--output-dir`, and supports optional `--manifest-dir` defaulting to `--output-dir`.
2. `scripts/run-swebench-batch.sh` exists and drives sequential batch execution by invoking `start-swebench.sh` per instance.
3. Both scripts enforce Codex-only unattended `codex -p local` behavior.
4. `--max-loops` exists (default 50) and governs execute-phase loop count per instance.
5. Batch mode processes instances in lexicographic `instance_id` order.
6. Per-instance isolation lives under `results/phase5/.../<instance>/` and not under `.ralph/`.
7. Per-instance artifacts (`.patch`, `.pred`, `.status.json`) are written with required schema.
8. `model_name_or_path` is exactly `qwen3-coder-next-FP8,codex,ralph`.
9. `failure_reason_code` is limited to fixed vocabulary (or `null` on success).
10. Missing required prompt files hard-fail before processing instances.
11. Blocked states are hard-fail for that instance (no blocked-mode prompt flow).
12. Batch continues on per-instance failures and emits run-level `predictions.jsonl`.
13. `start-swebench.sh` does not write run-level `predictions.jsonl`; `run-swebench-batch.sh` builds it from per-instance `.pred` files.
14. `start-swebench.sh` writes/updates run-level manifest at `<manifest_dir>/run_manifest.json` (`manifest_dir` defaults to `--output-dir`; batch passes `--manifest-dir <run_root>` so path resolves to `results/phase5/ralph-codex-local/<timestamp>/run_manifest.json`).
15. `scripts/prepare-swebench-codex-images.sh` exists, is manual/optional, and overwrites image tags in place.
16. Top-level `docs/` documents both new scripts and finished workflow contracts.
17. `run-swebench-batch.sh` passes `--output-dir` to `start-swebench.sh` as exactly `<run_root>/<instance_id>`.
18. `run-swebench-batch.sh` passes `--manifest-dir` to `start-swebench.sh` as exactly `<run_root>`.
19. `start-swebench.sh` always writes/updates `run_manifest.json`, including direct single-instance runs with omitted `--manifest-dir`.
