# Developer Guide

This guide is for contributors working on the `swebench-eval-next` root project.

## Scope and Source of Truth

- This project orchestrates SWE-Bench prediction/evaluation workflows on DGX Spark ARM64.
- Canonical runtime docs live under `docs/`.
- Project status is tracked in `docs/project-status.md`.
- Phase 3 SWE-Agent project is complete/closed. Completed outputs are in `results/phase3/` (299/300 multilingual test instances executed on ARM64).
- Phase 5 (`start-swebench.sh` + `run-swebench-batch.sh`) implementation is complete from archived planning docs, but no live SWE-Bench instance run has been executed yet.
- Treat `.ralph/` as planning/work-in-progress artifacts, not runtime state.

## Prerequisites

- ARM64 host (DGX Spark target for full runs).
- Docker.
- Python 3.11+ with `venv`.
- Local clones of patched forks:
  - `SWE-bench` branch `arm64-support`
  - `SWE-agent` branch `arm64-support`
- `spark-vllm-docker` clone for local vLLM serving.
- LiteLLM proxy configuration at `/home/sailorjoe6/litellm/litellm.yaml` for Codex local profile.

## Local Environment Setup

```bash
cd ~/Code/swebench-eval-next
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip

# Install patched dependencies from local clones
pip install -e ~/Code/SWE-bench
pip install -e ~/Code/SWE-agent
```

## Configuration

Primary config: `config/qwen3-vllm.yaml`

Key defaults:
- `instances.subset: multilingual`
- `instances.split: test`
- `instances.arch: arm64`
- `instances.deployment.pull: never`
- model endpoint: `http://localhost:8888/v1`

If you change dataset scope or architecture, update docs and any scripts that assume current defaults.

## Script Entry Points

- `scripts/launch-vllm.sh`
  - Starts/stops/checks vLLM in `spark-vllm-docker`.
- `scripts/launch-litellm.sh`
  - Starts/stops/checks LiteLLM bridge on `:8000`.
- `scripts/validate-vllm.sh`
  - Validates health/models/chat completion; writes to `results/phase1/`.
- `scripts/tag-arm64-images.sh`
  - Tags ARM64 SWE-Bench images to SWE-agent naming format.
- `scripts/run_predictions.sh`
  - Starts Phase 3 predictions (`sweagent run-batch`) into `results/phase3/full-run`.
- `scripts/check-eval-progress.sh`
  - Progress monitor for Phase 3 runs.
- `scripts/run_test_eval.sh`
  - Aggregates `.pred` and runs separate SWE-Bench evaluation.
- `scripts/view-traj.sh`
  - Pretty trajectory viewer for `.traj` files.

## Phase 3 Workflow (Completed Project / Reproducibility Path)

1. Start vLLM:
```bash
./scripts/launch-vllm.sh --daemon
./scripts/validate-vllm.sh
```

2. Start LiteLLM bridge:
```bash
./scripts/launch-litellm.sh
./scripts/launch-litellm.sh --health
```

3. Ensure ARM64 instance images are available and tagged:
```bash
./scripts/tag-arm64-images.sh
```

4. Run predictions:
```bash
./scripts/run_predictions.sh
```

5. Monitor:
```bash
./scripts/check-eval-progress.sh
```

6. Run evaluation (separate step):
```bash
./scripts/run_test_eval.sh --max_workers 1
```

## Phase 5 Status and Contract

Archived implementation spec/plan are at:
- `.ralph/plans/archive/swe-ralph/SPECIFICATION.md`
- `.ralph/plans/archive/swe-ralph/EXECUTION_PLAN.md`

Current state:
- Implementation complete for:
  - `scripts/start-swebench.sh`
  - `scripts/run-swebench-batch.sh`
  - `scripts/prepare-swebench-codex-images.sh`
- Contract/regression validation is recorded in the archived execution plan.
- No live SWE-Bench instance execution has been run for Phase 5 yet. Treat Phase 5 as implemented but not benchmark-executed.
- For behavior details, use `docs/implementation/phase5-runner.md`.
- Before running any Phase 5 batch, smoke-test Codex local routing:
```bash
codex exec -p local --dangerously-bypass-approvals-and-sandbox \
  "Respond with exactly: CODEX_LOCAL_BRIDGE_OK"
```
- For manual `python -m swebench.harness.run_evaluation` runs, always set `--report_dir` (or run from a results subdirectory) so summary `*.json` reports do not land in repo root.

## Quality Gates for Script Changes

For shell script work, run at minimum:

```bash
bash -n scripts/*.sh
```

If available:

```bash
shellcheck scripts/*.sh
```

For workflow changes, also run a smoke path:
- vLLM validation (`scripts/validate-vllm.sh`) when touching model-serving assumptions.
- one small prediction/eval sanity check when touching orchestration.

## Working Conventions

- Prefer deterministic behavior and explicit failures over implicit fallbacks.
- Keep prediction and evaluation as separate steps unless requirements change.
- Do not write runtime artifacts under `.ralph/`.
- Keep documentation synchronized with script behavior in `docs/`.

## Outputs and Git Hygiene

- Runtime outputs under `results/` and `logs/` are gitignored.
- Do not commit generated run artifacts.
- Commit only source/config/docs changes needed for reproducibility.
