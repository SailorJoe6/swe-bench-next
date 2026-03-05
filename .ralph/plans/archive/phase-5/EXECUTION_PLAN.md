# Execution Plan: Phase 5 Unresolved Campaign

## 1. Objective
Execute the Phase 5 unresolved campaign in three distinct phases with explicit blocked handoffs after Phase 1 and Phase 2.

## 2. Confirmed Operating Model (Authoritative)

This campaign is strictly phased:

1. **Phase 1**: prediction runner.
2. **Phase 2**: evaluation runner.
3. **Phase 3**: post-eval closeout (classification, troubleshooting, summary).

Critical control rules:

1. Phase 1 and Phase 2 are long-running script phases.
2. For both phases:
   - start the script,
   - monitor runtime health for **no more than 5 minutes**,
   - if unhealthy, troubleshoot and relaunch until healthy,
   - once healthy for 5 continuous minutes, update plan status, move plan/spec to `.ralph/plans/blocked/`, and stop and output instructions for monitoring the script, followed by the exact words `Blocked waiting on the script`.
3. User controls when next phase begins. Do not advance phases without explicit user direction.
4. Prediction and evaluation remain separate commands/phases for this campaign.

## 3. Campaign Root / Resume Contract

Use a persistent campaign root:

- `campaign_root="results/phase5/unresolved-campaign/current"`

Resume rules:

- Restart with the same `campaign_root`.
- Do not create a new timestamped campaign root when intent is resume.
- Resume logic must skip already-terminal instances instead of re-running from scratch.

## 4. Phase Status

- Phase 1 (prediction runner): completed
- Phase 2 (evaluation runner): running (healthy burn-in passed; blocked handoff active)
- Phase 3 (post-eval closeout): pending

### 4.1 Latest Phase 1 Runtime Checkpoint

- Launch command: `scripts/phase5-run-unresolved-campaign.sh --campaign-root results/phase5/unresolved-campaign/current`
- Session: `tmux` session `phase5_p1_20260302T115616Z`
- Launch time (UTC): `2026-03-02T11:56:16Z`
- Healthy gate satisfied (UTC): `2026-03-02T12:01:23Z`
- Health evidence during window:
  - session remained alive for full 5-minute window,
  - runner process remained active with child `start-swebench.sh`,
  - `results/phase5/unresolved-campaign/current/reports/run_unresolved_campaign.log` size/mtime advanced continuously.
- Current campaign root: `results/phase5/unresolved-campaign/current`
- Current target file: `results/phase5/unresolved-campaign/current/targets/unresolved_ids.txt` (97 ids)

### 4.2 Latest Phase 2 Runtime Checkpoint

- First launch command (UTC `2026-03-05T13:50:33Z`): `scripts/phase5-run-evals-sequential.sh --campaign-root results/phase5/unresolved-campaign/current`
- First-launch outcome: unhealthy (rapid exit) due evaluation input format mismatch (`.pred` path rejected by harness requiring `.json/.jsonl`).
- Remediation applied:
  - `scripts/phase5-eval-instance.sh` now normalizes non-`.json/.jsonl` prediction artifacts to a temporary `predictions.<run_id>.jsonl` path before calling `swebench.harness.run_evaluation`.
  - Regression tests passed:
    - `bash tests/test_phase5_eval_instance.sh`
    - `bash tests/test_phase5_run_evals_sequential.sh`
- Relaunch command: `scripts/phase5-run-evals-sequential.sh --campaign-root results/phase5/unresolved-campaign/current --retry-all`
- Session: `tmux` session `phase5_p2_20260305T135319Z`
- Relaunch time (UTC): `2026-03-05T13:53:19Z`
- Healthy gate satisfied (UTC): `2026-03-05T13:58:39Z`
- Health evidence during window:
  - session remained alive for full 5-minute window,
  - runner process remained active with child `phase5-eval-instance.sh` and `swebench.harness.run_evaluation`,
  - `run_evaluation` now receives normalized `.jsonl` predictions input path.

## 5. Phase 1: Prediction Runner

Scope:

1. Ensure prediction script exists and is correct (`scripts/phase5-run-unresolved-campaign.sh`).
2. Launch prediction script in detached `tmux`.
3. Monitor health up to 5 minutes.
4. Heal/relaunch if unhealthy.
5. On 5-minute healthy window:
   - append timestamped healthy-running status to this plan,
   - move files:
     - `.ralph/plans/SPECIFICATION.md` -> `.ralph/plans/blocked/SPECIFICATION.md`
     - `.ralph/plans/EXECUTION_PLAN.md` -> `.ralph/plans/blocked/EXECUTION_PLAN.md`
   - end with instructions for how to monitor the script, followed by the exact output: `Blocked waiting on the script`.

Definition of done:

- Prediction script is running healthy in detached `tmux`.
- Plan/spec moved to `.ralph/plans/blocked/`.
- Exact blocked output emitted.

## 6. Phase 2: Evaluation Runner

Scope:

1. Ensure evaluation script exists and is correct (`scripts/phase5-run-evals-sequential.sh`), implement/fix if needed.
2. Launch evaluation script in detached `tmux`.
3. Monitor health up to 5 minutes.
4. Heal/relaunch if unhealthy.
5. On 5-minute healthy window:
   - append timestamped healthy-running status to this plan,
   - move files:
     - `.ralph/plans/SPECIFICATION.md` -> `.ralph/plans/blocked/SPECIFICATION.md`
     - `.ralph/plans/EXECUTION_PLAN.md` -> `.ralph/plans/blocked/EXECUTION_PLAN.md`
   - end with instructions for how to monitor the script, followed by the exact output: `Blocked waiting on the script`.

Definition of done:

- Evaluation script is running healthy in detached `tmux`.
- Plan/spec moved to `.ralph/plans/blocked/`.
- Exact blocked output emitted.

## 7. Phase 3: Post-Eval Closeout

Scope:

1. Record per-instance prediction/evaluation outcomes.
2. Classify unresolved outcomes:
   - `agent_failure`
   - `container_porting_defect` / infra
3. Troubleshoot/fix container issues.
4. Re-run affected instances with traceability.
5. Produce final summary report.

Definition of done:

- All target instances have terminal evaluation/classification state.
- Container-fix reruns are recorded where needed.
- Final summary is produced.

## 8. Immediate Next Task

Current state: wait for Phase 2 script completion.

When user confirms Phase 2 has completed and explicitly directs continuation:

1. Continue with Phase 3 (post-eval closeout), reusing `campaign_root="results/phase5/unresolved-campaign/current"`.
2. Record per-instance terminal outcomes and classify unresolved failures (`agent_failure` vs infra/container).
3. Apply container-fix triage/rerun workflow where applicable.
4. Produce final campaign summary report.
