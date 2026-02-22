# Phase 5 Runner (Current State)

This document describes the current implementation state of the new SWE-Bench runner introduced by the active spec.

## Script

- `scripts/start-swebench.sh`

## Scope Implemented

The script currently implements **Phase 1 (single-instance runner skeleton)** plus a first **Phase 2 preflight milestone**:

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
- Runtime prompt assets are now tracked in-repo at:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
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

- Writes artifacts and manifest with `status: "incomplete"`.
- Exits with code `20` to indicate runtime loop work is still pending.

Current behavior when prompt preflight fails:

- Writes per-instance artifacts/manifest with `status: "failed"` and `failure_reason_code: "runtime_error"`.
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

- Container image checks and codex bootstrap fallback.
- Spec seeding from `problem_statement`.
- Plan/execute/handoff runtime loop and terminal-state classification.
- Final success/failed behavior and batch orchestrator integration.
