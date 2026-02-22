# Execution Plan: SWE-Bench Single-Runner First, Batch Driver Second

## 1. Purpose
Implement the spec in two explicit layers:
1. a robust single-instance runner (`scripts/start-swebench.sh`), then
2. a batch orchestrator (`scripts/run-swebench-batch.sh`) that loops over the single runner.

This plan intentionally avoids building a monolithic script with mixed concerns.

## 2. Locked Decisions
- Single-instance script: `scripts/start-swebench.sh`.
- Batch script: `scripts/run-swebench-batch.sh`.
- Optional manual prep utility: `scripts/prepare-swebench-codex-images.sh`.
- Runtime prompts must be loaded only from:
  - `ralph/prompts/plan.md`
  - `ralph/prompts/execute.md`
  - `ralph/prompts/handoff.md`
- `design.md` and `blocked.md` are not runtime prompts.
- Missing required prompt file is hard fail before instance execution.
- `model_name_or_path` literal: `qwen3-coder-next-FP8,codex,ralph`.
- `failure_reason_code` vocabulary is fixed.
- Always write `<instance>.status.json`.
- Batch order is lexicographic by `instance_id`.
- Run-level manifest is owned by `start-swebench.sh` at `<manifest_dir>/run_manifest.json`.
- `start-swebench.sh` must require `--output-dir` and write all per-instance runtime state there.
- `start-swebench.sh` supports optional `--manifest-dir`; default is `--output-dir`.
- `start-swebench.sh` always writes/updates `run_manifest.json` for every invocation (including direct single-instance runs).
- Timestamped run-root creation is owned by `run-swebench-batch.sh`.
- Batch per-instance output-dir convention is fixed: `<run_root>/<instance_id>`.
- Batch passes `--manifest-dir` as `<run_root>` to each instance invocation.
- Run-level `predictions.jsonl` is owned by `run-swebench-batch.sh` and built from per-instance `.pred` files.
- `.ralph/` is planning-only and never runtime state.

## 3. Current Status (2026-02-22)
Completed in this session:
- Phase 1 single-instance runner skeleton added at `scripts/start-swebench.sh`.
- CLI contracts implemented:
  - required `--instance-id`
  - required `--output-dir`
  - optional `--manifest-dir` (defaults to `--output-dir`)
  - `--max-loops` with default `50` and validation.
- Codex-only local-profile contract locked in script scaffolding (`codex -p local` command form).
- Per-instance/runtime scaffolding added:
  - output directory initialization
  - placeholder per-instance artifacts (`.patch`, `.pred`, `.status.json`)
  - run-level manifest creation/update at `<manifest_dir>/run_manifest.json`.
- Current skeleton semantics:
  - valid invocation exits with code `20` and `status=incomplete` by design until Phase 2 runtime loop is implemented.
  - if `codex` is unavailable on PATH, invocation exits non-zero with `status=failed`, `failure_reason_code=runtime_error`.
- Phase 1 validation tests added at `tests/test_start_swebench.sh`.
- Docs updated for current state at `docs/implementation/phase5-runner.md`.
- Phase 2 prompt-preflight milestone completed:
  - `scripts/start-swebench.sh` now hard-fails when any required runtime prompt file is missing.
  - tests now cover both preflight failure and success behavior in isolated runner roots.
- Phase 2 prompt-asset follow-up completed:
  - resolved `ralph` path tracking constraints by converting it from a gitlink entry to normal tracked files in this repository.
  - added tracked runtime prompts at `ralph/prompts/{plan,execute,handoff}.md`.
  - tests now include a repository-level prompt-availability regression for `scripts/start-swebench.sh`.
- Phase 2 metadata-seeding milestone completed:
  - `scripts/start-swebench.sh` now loads instance `problem_statement` metadata before runtime execution.
  - metadata source defaults to `SWE-bench/SWE-bench_Multilingual` (`multilingual`, `test`) with fixture override support via `SWE_BENCH_INSTANCES_FILE` for deterministic tests/dev runs.
  - per-instance seeded docs are written at `--output-dir/plans/SPECIFICATION.md` and `--output-dir/plans/EXECUTION_PLAN.md`.
  - tests now validate seeded docs and runtime_error handling for missing instance metadata.
- Latest pushed implementation commit for this phase: `b101472`.

Still not implemented:
- Phase 2 runtime core remainder (container/image checks, codex bootstrap fallback, plan/execute/handoff loop, final classification semantics).
- `scripts/run-swebench-batch.sh` (Phase 3).
- `scripts/prepare-swebench-codex-images.sh` (Phase 4).
- Full Phase 5 docs end-state describing finished batch + single runner behavior.

## 4. Execution Phases

### Phase 1: Single-Instance Runner Skeleton
Deliverables:
- Create `scripts/start-swebench.sh` with strict mode and CLI parsing.
- Require `--instance-id`.
- Require `--output-dir`.
- Add optional `--manifest-dir` (default to `--output-dir` when omitted).
- Add `--max-loops` (default `50`).
- Enforce unattended Codex local profile (`codex -p local`) and no profile override.

Definition of done:
- Script usage is clear.
- Invalid input fails fast and non-zero.
- Script is single-instance only (no batch dataset iteration).

### Phase 2: Single-Instance Runtime Core
Deliverables:
- Prompt preflight for required files in `ralph/prompts`.
- Per-instance state initialization under phase5 output path.
- Spec seed from instance `problem_statement`.
- Plan/execute/handoff loop with execute budget control.
- Terminal state detection and status classification.
- Codex bootstrap fallback and missing-image handling.
- Per-instance artifact writers:
  - `<instance>.patch`
  - `<instance>.pred`
  - `<instance>.status.json`
- Run-level manifest writer/updater at `<manifest_dir>/run_manifest.json` (`manifest_dir` defaults to `--output-dir`).

Definition of done:
- One invocation fully processes one instance and writes all required per-instance outputs.
- Failure reason fields are always populated correctly for non-success outcomes.

### Phase 3: Batch Orchestrator
Deliverables:
- Create `scripts/run-swebench-batch.sh`.
- Resolve batch scope:
  - default multilingual test split,
  - optional `--instance-file` subset.
- Lexicographically sort instance IDs.
- Create run root timestamp directory.
- Derive per-instance output directories under that run root as exactly `<run_root>/<instance_id>`.
- Invoke `scripts/start-swebench.sh` once per instance and pass:
  - `--output-dir <run_root>/<instance_id>`
  - `--manifest-dir <run_root>`
- Continue on per-instance failures.
- Aggregate run outputs from per-instance artifacts:
  - `predictions.jsonl` (from `<instance>.pred` files)

Definition of done:
- Batch driver contains orchestration only.
- Per-instance execution remains delegated to single runner.
- Aggregate predictions are complete and machine-readable.

### Phase 4: Manual Image Prep Utility
Deliverables:
- Create `scripts/prepare-swebench-codex-images.sh`.
- Inject codex binary and config into selected images.
- Overwrite same tags in place.
- Keep fully manual/optional.

Definition of done:
- Utility is functional and not auto-called by runtime scripts.

### Phase 5: Documentation Migration
Deliverables:
- Update top-level `docs/` for:
  - single-instance usage (`start-swebench.sh`),
  - batch usage (`run-swebench-batch.sh`),
  - output/failure contracts,
  - prediction vs evaluation separation.
- Ensure `ralph/docs` is not source-of-truth.

Definition of done:
- A contributor can run single and batch workflows from top-level docs alone.

## 5. Validation Matrix
### Static checks
- `bash -n scripts/start-swebench.sh scripts/run-swebench-batch.sh scripts/prepare-swebench-codex-images.sh`
- `shellcheck` for all scripts (if available)

### Functional checks
- Single instance success path.
- Single instance missing-image path.
- Single instance bootstrap-failure path.
- Batch run with unsorted subset input validates lexicographic ordering.
- Batch run continues after one forced failure.
- `--max-loops 1` behavior check.

### Contract checks
- `.pred` schema and metadata literal.
- `.status.json` always present.
- `start-swebench.sh` fails if `--output-dir` is omitted.
- `start-swebench.sh` defaults `--manifest-dir` to `--output-dir` when omitted.
- `start-swebench.sh` does not create run-level `predictions.jsonl`.
- `start-swebench.sh` creates/updates run-level manifest at `<manifest_dir>/run_manifest.json`.
- `start-swebench.sh` writes/updates manifest in direct single-instance mode as well.
- `run-swebench-batch.sh` creates `predictions.jsonl` by aggregating per-instance `.pred` files.
- `run-swebench-batch.sh` does not own manifest creation.
- `run-swebench-batch.sh` passes `--manifest-dir <run_root>` for each instance.
- failure reason vocabulary enforcement.
- manifest path exactness.
- no runtime state writes under `.ralph/`.
- no runtime prompt usage outside `plan.md`, `execute.md`, `handoff.md`.

## 6. Sequencing (Strict)
1. Phase 1
2. Phase 2
3. Phase 3
4. Phase 4
5. Phase 5
6. Run validation matrix
7. Final acceptance review against spec criteria

## 7. Completion Gate
Complete only when:
- All spec acceptance criteria are satisfied.
- Validation matrix checks are executed and results documented.
- Docs in top-level `docs/` reflect final workflow behavior.
- No open architectural decisions remain.

## 8. Open Decisions
No open decisions currently.

## 9. Beads Tracking
- Umbrella feature: `swebench-eval-next-4as` (in progress)
- Remaining follow-ups:
  - `swebench-eval-next-4as.1` (Phase 2 runtime core)
  - `swebench-eval-next-4as.2` (Phase 3 batch orchestrator)
  - `swebench-eval-next-4as.3` (Phase 4 image prep utility)
  - `swebench-eval-next-4as.4` (Phase 5 docs completion)

## 10. Handoff Start Point
1. Continue `swebench-eval-next-4as.1` (Phase 2 runtime core) in this order:
   - container/image + codex bootstrap fallback (`missing_image`/`codex_bootstrap_failed` mapping),
   - execute-loop with `--max-loops` budget and terminal classification.
2. Keep `scripts/start-swebench.sh` single-instance only; defer all batch behavior to `swebench-eval-next-4as.2`.
3. First concrete implementation target:
   - in `scripts/start-swebench.sh`, add image existence check for `sweb.eval.arm64.<instance>:latest` and map failures to `status=failed`, `failure_reason_code=missing_image`;
   - add codex bootstrap fallback path and map failures to `status=failed`, `failure_reason_code=codex_bootstrap_failed`;
   - keep per-instance artifact contract unchanged (`.patch`, `.pred`, `.status.json` always emitted).
4. Validation to add immediately with that change:
   - extend `tests/test_start_swebench.sh` with deterministic cases for `missing_image` and `codex_bootstrap_failed`;
   - run `bash -n scripts/start-swebench.sh tests/test_start_swebench.sh` and `tests/test_start_swebench.sh`.
