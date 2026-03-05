# Specification: Phase 5 Unresolved Campaign (3-Phase Model)

## Objective
Run a benchmark-scale Phase 5 campaign for all Phase 3 unresolved instances using three separate phases:
1. Prediction-run phase.
2. Evaluation-run phase.
3. Post-eval closeout phase (classification, troubleshooting, summary).

## Authoritative Phase Model

### Phase 1: Prediction Runner Phase
- Build/confirm prediction-run script.
- Start prediction-run script.
- Monitor runtime health for no more than 5 minutes.
- If unhealthy, troubleshoot and relaunch until healthy.
- Once healthy for 5 continuous minutes:
  - update execution plan status,
  - move spec and plan to `.ralph/plans/blocked/`,
  - stop and emit exact message: `Blocked waiting on the script`.

### Phase 2: Evaluation Runner Phase
- Build/confirm evaluation-run script (script may already exist).
- Start evaluation-run script.
- Monitor runtime health for no more than 5 minutes.
- If unhealthy, troubleshoot and relaunch until healthy.
- Once healthy for 5 continuous minutes:
  - update execution plan status,
  - move spec and plan to `.ralph/plans/blocked/`,
  - stop and emit exact message: `Blocked waiting on the script`.

### Phase 3: Post-Eval Closeout Phase
- After user confirms evaluation run completion, process outcomes:
  - record per-instance results,
  - classify unresolved outcomes (agent failure vs container/infra),
  - troubleshoot and fix container issues,
  - re-run affected instances where applicable,
  - produce final campaign summary.

## Required System Behavior
- Resume behavior must use one persistent campaign root.
- Restarting a phase must reuse the same campaign root; do not create a new timestamped root when the intent is resume.
- Phase transitions are user-controlled:
  - after Phase 1 blocked handoff, wait for user direction,
  - after Phase 2 blocked handoff, wait for user direction.
- Prediction and evaluation are separate long-running phases for this campaign.
- Per-instance outcomes must be recorded in machine-readable campaign state.
- Retry history must be preserved append-only.

## Completion Criteria
Campaign is complete when:
1. Phase 1 prediction run has completed for campaign targets.
2. Phase 2 evaluation run has completed for produced predictions.
3. Phase 3 closeout has classified failures and handled container-fix reruns where needed.
4. Final summary report is produced.

## Runtime Status Checkpoint
- Phase 1 prediction runner was launched at `2026-03-02T11:56:16Z` (UTC) using campaign root `results/phase5/unresolved-campaign/current`.
- A 5-minute healthy runtime gate was satisfied at `2026-03-02T12:01:23Z` (UTC).
- Phase 2 evaluation runner first launch at `2026-03-05T13:50:33Z` (UTC) exited unhealthy due `.pred` prediction path format mismatch with harness (`.json/.jsonl` required).
- Phase 2 evaluation runner relaunch at `2026-03-05T13:53:19Z` (UTC) passed the 5-minute healthy runtime gate at `2026-03-05T13:58:39Z` (UTC) after prediction-input normalization fix in `scripts/phase5-eval-instance.sh`.
- Campaign is now in blocked handoff state waiting for user direction before Phase 3.
