# Phase 5 Unresolved Campaign Scaffolding

This document tracks the new rerun campaign scaffolding for `.ralph/plans/SPECIFICATION.md` (Phase 5 retry of unresolved Phase 3 instances).

## Current Scope

Implemented in this step:

- `scripts/phase5-build-unresolved-targets.sh`
- `scripts/phase5-run-unresolved-campaign.sh`
- `scripts/phase5-eval-instance.sh`
- `scripts/phase5-run-evals-sequential.sh`
- `scripts/phase5-summarize-campaign.sh`
- `scripts/phase5-record-container-fix.sh`
- `scripts/phase5-select-container-fix-targets.sh`
- `scripts/phase5-triage-container-defect.sh`

## Restart Contract

- Use one persistent campaign root for the entire unresolved campaign lifecycle.
- Default root is `results/phase5/unresolved-campaign/current`.
- Stop/restart must reuse the same campaign root so resume logic can skip instances with existing terminal attempts.
- Do not create a new timestamped campaign root when the intent is to resume an existing campaign.

## Target Builder Script

`scripts/phase5-build-unresolved-targets.sh` reads Phase 3 evaluation summary output and writes a deterministic unresolved target list for a campaign run root.

### Usage

```bash
scripts/phase5-build-unresolved-targets.sh \
  [--phase3-summary results/phase3/full-run.eval-batch.json] \
  [--campaign-root results/phase5/unresolved-campaign/current] \
  [--force]
```

### Behavior

- Reads `unresolved_ids` from the Phase 3 summary JSON.
- Normalizes IDs (trim), removes blanks, deduplicates, and sorts lexicographically.
- Creates campaign directories:
  - `<campaign_root>/targets/`
  - `<campaign_root>/state/`
  - `<campaign_root>/reports/`
- Writes target file:
  - `<campaign_root>/targets/unresolved_ids.txt`
- If target file already exists and `--force` is not set, reuses the existing file (idempotent restart-safe behavior).

### Output

On success the script prints:

- `campaign_root=<path>`
- `phase3_summary=<path>`
- `target_file=<path>`
- `target_count=<n>`

## Regression Test

- `tests/test_phase5_build_unresolved_targets.sh`
  - validates sorted/dedup target extraction
  - validates missing-summary error handling
  - validates idempotent existing-target reuse and `--force` overwrite behavior

## Prediction Campaign Runner Script

`scripts/phase5-run-unresolved-campaign.sh` runs unresolved targets one instance at a time using `scripts/start-swebench.sh`, writes append-only attempt history, and supports resumable operation.

### Usage

```bash
scripts/phase5-run-unresolved-campaign.sh \
  [--campaign-root results/phase5/unresolved-campaign/current] \
  [--targets-file <path>] \
  [--max-loops 50] \
  [--retry-all] \
  [--container-fix-id <fix_id>] \
  [--immediate-eval]
```

### Behavior

- Reads target IDs from:
  - default `<campaign_root>/targets/unresolved_ids.txt`, or
  - explicit `--targets-file`
- Runs one instance at a time, foreground/blocking:
  - `scripts/start-swebench.sh --instance-id <id> --output-dir <campaign_root>/instances/<id> --manifest-dir <campaign_root>`
- Continues through failures instead of aborting on first error.
- Records one append-only attempt row per invocation in:
  - `<campaign_root>/state/attempts.jsonl`
- Maintains resume index in:
  - `<campaign_root>/state/instance_latest.json`
- Skips target IDs whose latest prediction status is terminal (`success|failed|incomplete`) unless `--retry-all` is provided.
- Writes runner log:
  - `<campaign_root>/reports/run_unresolved_campaign.log`
- If `--container-fix-id` is provided, new append-only attempt rows include that `container_fix_id` value for retry traceability.
- If `--immediate-eval` is provided:
  - each non-empty patch is evaluated before moving to the next target instance,
  - evaluation orchestration is delegated to `scripts/phase5-run-evals-sequential.sh` with a one-instance targets file,
  - campaign summary line includes immediate-eval counters (`eval_attempted`, `eval_resolved`, `eval_unresolved`, `eval_error`).

### State Notes

- Prediction attempts are initially written with:
  - `evaluation.executed=false`
  - `evaluation.result=not_run`
  - `classification=infra_unclassified`
- In `--immediate-eval` mode these fields are updated during the same pass before advancing to the next instance.
- Without `--immediate-eval`, these fields are updated later by `scripts/phase5-run-evals-sequential.sh`.

### Regression Test

- `tests/test_phase5_run_unresolved_campaign.sh`
  - validates one-at-a-time delegated prediction invocations
  - validates continue-on-failure behavior
  - validates append-only `attempts.jsonl` history
  - validates resume skip behavior and `--retry-all` behavior
  - validates fix-linked retry attempts set `container_fix_id` without mutating earlier rows
  - validates `--immediate-eval` prediction->eval ordering and in-place attempt/latest state updates

## Container Fix Registry Script

`scripts/phase5-record-container-fix.sh` appends container-porting fix records to campaign state for explicit traceability.

### Usage

```bash
scripts/phase5-record-container-fix.sh \
  --campaign-root results/phase5/unresolved-campaign/current \
  --container-fix-id fix-001 \
  --description "Fix ARM64 container startup command" \
  --file-changed swebench/harness/docker_build.py \
  --affected-instance repo__alpha-1 \
  [--affected-instances-file <path>] \
  [--date 2026-03-02T03:00:00Z]
```

### Behavior

- Appends one row per fix to:
  - `<campaign_root>/state/container_fixes.jsonl`
- Enforces unique `container_fix_id` values.
- Normalizes and deduplicates:
  - `files_changed`
  - `affected_instances`
- Stores `affected_instances` in sorted order for deterministic downstream selection.

### Regression Test

- `tests/test_phase5_record_container_fix.sh`
  - validates append behavior and output shape
  - validates deduped/stable field normalization
  - validates duplicate `container_fix_id` rejection

## Container Fix Rerun Selector Script

`scripts/phase5-select-container-fix-targets.sh` deterministically selects rerun instance IDs for a specific `container_fix_id`.

### Usage

```bash
scripts/phase5-select-container-fix-targets.sh \
  --campaign-root results/phase5/unresolved-campaign/current \
  --container-fix-id fix-001 \
  [--output <path>]
```

### Behavior

- Reads fix records from:
  - `<campaign_root>/state/container_fixes.jsonl`
- Reads campaign target order from:
  - `<campaign_root>/targets/unresolved_ids.txt`
- Selects rerun IDs as:
  - `affected_instances ∩ campaign_targets`
- Emits IDs to stdout (one per line) in deterministic campaign target order.
- Optionally writes the same list to `--output`.

### Regression Test

- `tests/test_phase5_select_container_fix_targets.sh`
  - validates deterministic affected-instance selection for one fix
  - validates output-file parity with stdout
  - validates missing-fix error handling

## Post-Eval Container Defect Triage Script

`scripts/phase5-triage-container-defect.sh` promotes selected evaluated attempts from `infra_unclassified` to explicit `container_porting_defect` classification after manual triage.

### Usage

```bash
scripts/phase5-triage-container-defect.sh \
  --campaign-root results/phase5/unresolved-campaign/current \
  --note "ARM64 container startup failure in test harness runtime" \
  --container-fix-id fix-001 \
  --instance-id repo__alpha-1 \
  [--instance-ids-file <path>] \
  [--attempt-id <attempt_id>]
```

### Behavior

- Selects attempts by:
  - latest attempt for each `--instance-id` / `--instance-ids-file` instance, and/or
  - explicit `--attempt-id` values.
- Requires selected attempts to be evaluation failures:
  - `evaluation.result=eval_error`
  - `classification` currently `infra_unclassified` or `container_porting_defect`.
- Promotes selected attempts to:
  - `classification=container_porting_defect`
- If `--container-fix-id` is provided:
  - validates fix ID exists exactly once in `state/container_fixes.jsonl`
  - writes `container_fix_id` onto promoted attempt rows.
- Appends triage traceability in `notes` and writes `triaged_at`.
- Updates `state/instance_latest.json` when the promoted attempt is the current latest attempt for that instance.

### Regression Test

- `tests/test_phase5_triage_container_defect.sh`
  - validates promotion of selected latest/explicit attempts
  - validates `container_fix_id` linkage and `instance_latest.json` sync
  - validates rejection when selected attempt is not an eval-error row

## Per-Instance Evaluation Wrapper Script

`scripts/phase5-eval-instance.sh` runs SWE-Bench harness evaluation for one prediction artifact and writes a machine-readable result file for campaign-state ingestion.

### Usage

```bash
scripts/phase5-eval-instance.sh \
  --campaign-root results/phase5/unresolved-campaign/current \
  --instance-id <instance_id> \
  [--predictions-path <path>] \
  [--run-id phase5-eval-<instance_id>] \
  [--dataset-name SWE-bench/SWE-bench_Multilingual] \
  [--max-workers 1] \
  [--namespace none] \
  [--arch arm64]
```

### Behavior

- Resolves prediction path from:
  - default `<campaign_root>/instances/<instance_id>/<instance_id>.pred`, or
  - explicit `--predictions-path`
- Runs:
  - `python -m swebench.harness.run_evaluation`
  - with explicit `--namespace` and `--arch` (defaults `none` + `arm64`)
  - with explicit `--report_dir <campaign_root>/reports/eval/<instance_id>`
- Derives evaluation summary artifact directory from campaign root:
  - `<campaign_root>/evaluations`
  - ensures directory exists without deleting existing artifacts
  - refuses to overwrite existing summary JSON for the same `run_id`
- Writes harness log to:
  - `<campaign_root>/reports/eval/<instance_id>/run_evaluation.log`
- Runs harness with working directory set to `<campaign_root>/evaluations` so summary JSON artifacts land there.
- Locates harness summary JSON under `<campaign_root>/evaluations` and derives result:
  - `resolved` when `<instance_id>` is in `resolved_ids`
  - `unresolved` when `<instance_id>` is in `unresolved_ids`
  - `eval_error` when `<instance_id>` is in `error_ids`
- Writes machine-readable output:
  - `<campaign_root>/state/evals/<instance_id>.eval.json`

### Exit Behavior

- Exits `0` when evaluation command succeeds and summary parsing succeeds (`resolved|unresolved|eval_error` are all valid outcomes).
- Exits non-zero when harness command fails or summary artifact parsing fails.

### Regression Test

- `tests/test_phase5_eval_instance.sh`
  - mocks `python -m swebench.harness.run_evaluation`
  - validates expected harness CLI flags (`--namespace none`, `--arch arm64`, deterministic run/report paths)
  - validates parsed `unresolved` result output file shape
  - validates non-zero propagation and `eval_error` result emission for harness runtime failure

## Sequential Evaluation Campaign Runner Script

`scripts/phase5-run-evals-sequential.sh` orchestrates one-instance-at-a-time evaluations for unresolved campaign targets and wires outcomes back into campaign attempt state.

### Usage

```bash
scripts/phase5-run-evals-sequential.sh \
  --campaign-root results/phase5/unresolved-campaign/current \
  [--targets-file <path>] \
  [--dataset-name SWE-bench/SWE-bench_Multilingual] \
  [--max-workers 1] \
  [--namespace none] \
  [--arch arm64] \
  [--run-id-prefix phase5-eval] \
  [--retry-all]
```

### Behavior

- Reads target IDs from:
  - default `<campaign_root>/targets/unresolved_ids.txt`, or
  - explicit `--targets-file`
- Resolves each target to its latest attempt from:
  - `<campaign_root>/state/attempts.jsonl`
  - `<campaign_root>/state/instance_latest.json`
- Evaluates only when latest attempt has `prediction.patch_non_empty=true`.
- Delegates evaluation in foreground/blocking mode:
  - `scripts/phase5-eval-instance.sh --predictions-path <latest_pred_path>`
- Resume behavior:
  - skips attempts whose `evaluation.result` is already terminal (`resolved|unresolved|eval_error`) unless `--retry-all` is set.
- Writes orchestration log:
  - `<campaign_root>/reports/run_evals_sequential.log`
- Updates campaign state for evaluated attempt:
  - `evaluation.executed=true`
  - `evaluation.result=resolved|unresolved|eval_error`
  - `evaluation.result_path`, `evaluation.exit_code`, `evaluation.updated_at`
  - `classification` seed mapping:
    - `resolved` -> `resolved`
    - `unresolved` -> `agent_failure`
    - `eval_error` -> `infra_unclassified`
- Post-eval deterministic promotion to container defects is handled separately via:
  - `scripts/phase5-triage-container-defect.sh`

### Exit Behavior

- Exits `0` when all executed evaluations ended in `resolved|unresolved`.
- Exits `1` when one or more executed evaluations ended in `eval_error`.

### Regression Test

- `tests/test_phase5_run_evals_sequential.sh`
  - validates one-at-a-time eligible evaluation invocation ordering
  - validates skip behavior for empty-patch and already-terminal attempts
  - validates attempt/instance state updates for `resolved` and `eval_error`
  - validates resume rerun skips already-terminal evaluation attempts

## Campaign Summary Script

`scripts/phase5-summarize-campaign.sh` builds the campaign-level summary from target IDs and current attempt state, then writes the final machine-readable report.

### Usage

```bash
scripts/phase5-summarize-campaign.sh \
  --campaign-root results/phase5/unresolved-campaign/current \
  [--targets-file <path>] \
  [--output <path>]
```

### Behavior

- Reads target IDs from:
  - default `<campaign_root>/targets/unresolved_ids.txt`, or
  - explicit `--targets-file`
- Reads per-instance attempt history from:
  - `<campaign_root>/state/attempts.jsonl`
  - `<campaign_root>/state/instance_latest.json`
- Selects one summarized attempt per target:
  - prefers `instance_latest.json` `attempt_id` when present,
  - otherwise falls back to the newest attempt row for that instance in `attempts.jsonl`.
- Computes required bucket counts:
  - `resolved_by_phase5`
  - `unresolved_agent_failure`
  - `unresolved_infra_or_container`
- Tracks `not_attempted` targets separately so incomplete campaign coverage is explicit.
- Writes final summary JSON:
  - default `<campaign_root>/reports/final_summary.json`
- Prints key-value summary lines to stdout for easy operator review.

### Classification Mapping

- `classification=resolved` or `evaluation.result=resolved` -> `resolved_by_phase5`
- `classification=agent_failure` or `evaluation.result=unresolved` -> `unresolved_agent_failure`
- all other attempted states (including `infra_unclassified`, `container_porting_defect`, `eval_error`, `not_run`) -> `unresolved_infra_or_container`
- no attempt row for target -> `not_attempted`

### Regression Test

- `tests/test_phase5_summarize_campaign.sh`
  - validates required bucket counts in `reports/final_summary.json`
  - validates per-instance bucket classification report content
  - validates latest-attempt selection honors `instance_latest.json`
