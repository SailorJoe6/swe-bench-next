# Phase 5 Runner (Current State)

This document describes the current implementation state of the new SWE-Bench runner introduced by the active spec.

## Script

- `scripts/start-swebench.sh`

## Scope Implemented

The script currently implements **Phase 1 (single-instance runner skeleton)** plus multiple **Phase 2 pre-execution milestones**:

- Requires `--instance-id <id>`.
- Requires `--output-dir <path>`.
- Supports optional `--manifest-dir <path>` (defaults to `--output-dir`).
- Supports `--max-loops <n>` (default: `50`; positive integer validation).
- Enforces Codex-only local profile contract by locking command form to `codex -p local ...`.
- Performs required runtime prompt preflight for:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
  Missing any of these files hard-fails the invocation.
- Loads instance metadata and `problem_statement` before execution:
  - default source: `SWE-bench/SWE-bench_Multilingual` (`multilingual`, `test`)
  - test/dev override: `SWE_BENCH_INSTANCES_FILE=<json|jsonl>`
- Seeds per-instance planning docs under `--output-dir/plans/`:
  - `SPECIFICATION.md` (from `problem_statement`)
  - `EXECUTION_PLAN.md` (seeded in-progress scaffold)
- Runtime prompt assets are now tracked in-repo at:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
- Performs container/image pre-execution checks for:
  - required image tag `sweb.eval.arm64.<instance_id>:latest` (`missing_image` on failure)
  - codex availability inside the instance image container context
- Attempts runtime codex bootstrap fallback into the image when codex is missing:
  - binary source: `/home/sailorjoe6/.cargo/bin/codex` (or `CODEX_BOOTSTRAP_BIN_PATH` override)
  - config source: `/home/sailorjoe6/.codex/config.toml` (or `CODEX_BOOTSTRAP_CONFIG_PATH` override)
  - bootstrap failures map to `failure_reason_code: "codex_bootstrap_failed"`
- Initializes per-instance runtime directory structure under the provided output directory.
- Writes per-instance artifact placeholders:
  - `<instance>.patch`
  - `<instance>.pred`
  - `<instance>.status.json`
- Writes/updates run-level manifest:
  - `<manifest_dir>/run_manifest.json`

## Current Status Semantics

Phase 1 is scaffolding-only, so instance execution is not implemented yet.

Current behavior for valid invocations (with required runtime prompts present):

- Writes seeded plan docs, artifacts, and manifest with `status: "incomplete"`.
- Exits with code `20` to indicate runtime loop work is still pending.

Current behavior when prompt preflight fails:

- Writes per-instance artifacts/manifest with `status: "failed"` and `failure_reason_code: "runtime_error"`.
- Exits with code `1`.

Current behavior when metadata/problem statement loading fails:

- Writes per-instance artifacts/manifest with `status: "failed"` and `failure_reason_code: "runtime_error"`.
- Exits with code `1`.

Current behavior when the required image is missing:

- Writes per-instance artifacts/manifest with `status: "failed"` and `failure_reason_code: "missing_image"`.
- Exits with code `1`.

Current behavior when codex bootstrap fails:

- Writes per-instance artifacts/manifest with `status: "failed"` and `failure_reason_code: "codex_bootstrap_failed"`.
- Exits with code `1`.

## Usage

```bash
scripts/start-swebench.sh \
  --instance-id <instance_id> \
  --output-dir <path> \
  [--manifest-dir <path>] \
  [--max-loops 50]
```

## Notes

Remaining work from the plan includes:

- Plan/execute/handoff runtime loop and terminal-state classification.
- Final success/failed behavior and batch orchestrator integration.
