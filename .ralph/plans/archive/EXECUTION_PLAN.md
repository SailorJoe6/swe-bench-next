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
Completed to date:
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
- Current single-runner runtime semantics:
  - `scripts/start-swebench.sh` now runs plan + execute/handoff loop with execute-pass budgeting via `--max-loops`.
  - terminal classification/exit codes are now active: `success`/`0`, `failed`/`1`, `incomplete`/`20`.
  - precheck/runtime failures map to explicit reason codes (`missing_image`, `codex_bootstrap_failed`, `runtime_error`, `blocked`, `incomplete`).
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
- Phase 2 image/bootstrap precheck milestone completed:
  - `scripts/start-swebench.sh` now enforces image availability for `sweb.eval.arm64.<instance>:latest` and maps failures to `status=failed`, `failure_reason_code=missing_image`.
  - script now checks codex availability inside the instance image and runs bootstrap fallback when missing.
  - bootstrap failures now map to `status=failed`, `failure_reason_code=codex_bootstrap_failed`.
  - tests now include deterministic missing-image and bootstrap-failure regressions in `tests/test_start_swebench.sh`.
- Phase 2 execute-loop/classification milestone completed:
  - `scripts/start-swebench.sh` now executes `plan` once, then runs `execute` + `handoff` passes with `--max-loops` budget control.
  - terminal classification now maps from per-instance plan state:
    - `plans/archive` + non-empty patch => `status=success`, `failure_reason_code=null`
    - `plans/blocked` => `status=failed`, `failure_reason_code=blocked`
    - root plans at loop end => `status=incomplete`, `failure_reason_code=incomplete`
  - exit semantics are now: `0` success, `1` failed, `20` incomplete.
  - tests now include deterministic success, blocked, and max-loop budget regressions.
- Phase 3 batch orchestrator milestone completed:
  - added `scripts/run-swebench-batch.sh` with sequential orchestration only.
  - batch scope resolution now supports:
    - default multilingual/test scope, and
    - optional `--instance-file` subset.
  - instance execution order is deterministic lexicographic `instance_id`.
  - batch runner creates one timestamped run root at `results/phase5/ralph-codex-local/<timestamp>/`.
  - each per-instance invocation now passes:
    - `--output-dir <run_root>/<instance_id>`
    - `--manifest-dir <run_root>`
  - batch continues after per-instance failures and aggregates `<instance>.pred` to `<run_root>/predictions.jsonl`.
  - added dedicated regression coverage in `tests/test_run_swebench_batch.sh` for:
    - deterministic ordering on unsorted subset input,
    - continue-on-failure behavior,
    - `predictions.jsonl` aggregation.
- Phase 3 docs update completed:
  - updated `docs/implementation/phase5-runner.md` to document both single-instance and batch contracts.
  - updated docs indexes (`docs/README.md`, `docs/implementation/README.md`) for Phase 5 batch visibility.
- Phase 4 manual image prep utility completed:
  - added `scripts/prepare-swebench-codex-images.sh` as a manual optional utility.
  - utility now injects codex binary/config into selected images and commits in place to the same tags.
  - target selectors now support `--instance-id`, `--instance-file`, `--image`, and `--all-local-images`.
  - added `--dry-run` target preflight mode.
  - added regression coverage at `tests/test_prepare_swebench_codex_images.sh` for selector validation, successful prep flow, missing bootstrap source, and partial missing-image failure behavior.
  - added docs at `docs/implementation/prepare-codex-images.md` and updated docs indexes.
- Handoff checkpoint for next session:
  - latest pushed commit on `origin/main` includes this handoff refresh and acceptance closure sequencing guidance.
  - runner regression scripts currently passing:
    - `tests/test_start_swebench.sh`
    - `tests/test_run_swebench_batch.sh`
    - `tests/test_prepare_swebench_codex_images.sh`
- Phase 5 documentation migration milestone completed:
  - rewrote `docs/implementation/phase5-runner.md` as final workflow contract documentation (single-instance, batch, outputs, failure vocabulary, classification, manifest behavior, and prediction/evaluation separation).
  - updated documentation indexes in `docs/README.md` and `docs/implementation/README.md` to point at finalized Phase 5 docs.
  - added `docs/guides/quickstart.md` pointer to the Phase 5 runner workflow doc.

Still not implemented:
- None.

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
- Umbrella feature: `swebench-eval-next-4as` (closed)
- Final follow-up task: `swebench-eval-next-4as.6` (closed)

## 10. Handoff Start Point
1. Spec and plan are complete and archived.
2. All acceptance criteria have passing evidence recorded in this plan.
3. Continue from new planning docs if a follow-on specification is opened.

## 11. Final Validation + Acceptance Review (2026-02-22)

### 11.1 Validation Matrix Results

Static checks:
- `bash -n scripts/start-swebench.sh scripts/run-swebench-batch.sh scripts/prepare-swebench-codex-images.sh` -> PASS
- `shellcheck scripts/start-swebench.sh scripts/run-swebench-batch.sh scripts/prepare-swebench-codex-images.sh` -> SKIPPED (`shellcheck` not installed in environment)

Functional checks:
- `tests/test_start_swebench.sh` -> PASS
- `tests/test_run_swebench_batch.sh` -> PASS
- `tests/test_prepare_swebench_codex_images.sh` -> PASS

### 11.2 Acceptance Criteria Matrix

1. PASS - `scripts/start-swebench.sh` enforces required `--instance-id` and `--output-dir`, supports optional `--manifest-dir` defaulting to `--output-dir` (script CLI parser + `tests/test_start_swebench.sh`).
2. PASS - `scripts/run-swebench-batch.sh` invokes `start-swebench.sh` sequentially per instance (`scripts/run-swebench-batch.sh`, `tests/test_run_swebench_batch.sh`).
3. PASS - runners reject profile/Claude overrides and execute Codex unattended with `-p local` (`scripts/start-swebench.sh`, `scripts/run-swebench-batch.sh`).
4. PASS - `--max-loops` exists with default `50` and controls execute passes (`scripts/start-swebench.sh`, `tests/test_start_swebench.sh` max-loop regression).
5. PASS - batch sorts instance IDs lexicographically before invocation (`collect_instance_ids` sort in batch script + ordering assertions in `tests/test_run_swebench_batch.sh`).
6. PASS - per-instance state is under `--output-dir` (`plans/`, `logs/`, artifacts) and no `.ralph/` runtime writes exist (`scripts/start-swebench.sh`).
7. PASS - `.patch`, `.pred`, `.status.json` are always written (`scripts/start-swebench.sh`, `tests/test_start_swebench.sh`).
8. PASS - `.pred` always sets `model_name_or_path` to `qwen3-coder-next-FP8,codex,ralph` (`write_pred_json`, all runner tests).
9. PASS - reason-code vocabulary is constrained to fixed values with `null` on success (`scripts/start-swebench.sh` classification branches + tests for success/failure/incomplete).
10. PASS - missing required runtime prompts hard-fails before execution (`collect_missing_prompts` + `run_case_missing_runtime_prompts` test).
11. PASS - blocked terminal plan state is hard-failed, no blocked prompt path (`classify_plan_state` + `run_case_blocked_terminal_classification` test).
12. PASS - batch continues on per-instance failure and emits `predictions.jsonl` (`tests/test_run_swebench_batch.sh` continue-on-failure case).
13. PASS - single runner does not emit run-level `predictions.jsonl`; batch builds it from per-instance `.pred` files (`scripts/start-swebench.sh`, `scripts/run-swebench-batch.sh`, batch tests).
14. PASS - single runner always writes/updates manifest at `<manifest_dir>/run_manifest.json` with defaulting behavior (`scripts/start-swebench.sh`, default-manifest and failure-path tests).
15. PASS - manual optional `scripts/prepare-swebench-codex-images.sh` exists and overwrites image tags in place (`docs/implementation/prepare-codex-images.md`, `tests/test_prepare_swebench_codex_images.sh`).
16. PASS - top-level `docs/` documents both new scripts and workflow contracts (`docs/implementation/phase5-runner.md`, `docs/README.md`).
17. PASS - batch passes instance output dir as exactly `<run_root>/<instance_id>` (`scripts/run-swebench-batch.sh`, ordering test invocation assertions).
18. PASS - batch passes `--manifest-dir` as exactly `<run_root>` (`scripts/run-swebench-batch.sh`, ordering test invocation assertions).
19. PASS - single runner writes/updates manifest for direct runs when `--manifest-dir` is omitted (`tests/test_start_swebench.sh` default manifest case).

### 11.3 Final Outcome

- All 19 specification acceptance criteria pass with test and script evidence.
- No remaining implementation work exists for this spec/plan pair.
