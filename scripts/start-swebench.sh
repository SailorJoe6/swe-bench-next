#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="SWE-bench/SWE-bench_Multilingual"
DATASET_SUBSET="multilingual"
DATASET_SPLIT="test"
MODEL_NAME_OR_PATH="qwen3-coder-next-FP8,codex,ralph"
CODEX_PROFILE="local"
INSTANCE_FIXTURE_ENV_VAR="SWE_BENCH_INSTANCES_FILE"
MAX_LOOPS_DEFAULT=50
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/ralph/prompts"
REQUIRED_PROMPTS=(plan.md execute.md handoff.md)

INSTANCE_ID=""
OUTPUT_DIR=""
MANIFEST_DIR=""
MAX_LOOPS="$MAX_LOOPS_DEFAULT"

usage() {
  cat <<USAGE
Usage: scripts/start-swebench.sh --instance-id <id> --output-dir <path> [options]

Required:
  --instance-id <id>     SWE-Bench instance ID to process
  --output-dir <path>    Per-instance runtime output directory

Options:
  --manifest-dir <path>  Run manifest directory (default: --output-dir)
  --max-loops <n>        Execute-loop pass budget (default: ${MAX_LOOPS_DEFAULT})
  -h, --help             Show this help message

Behavior:
  - Single-instance only
  - Codex-only unattended contract (hardcoded: codex -p local)
USAGE
}

error() {
  echo "Error: $*" >&2
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

collect_missing_prompts() {
  local missing=()
  local prompt_file=""

  for prompt_file in "${REQUIRED_PROMPTS[@]}"; do
    if [[ ! -f "$PROMPTS_DIR/$prompt_file" ]]; then
      missing+=("$PROMPTS_DIR/$prompt_file")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
    return 1
  fi

  return 0
}

load_instance_problem_statement() {
  local instance_id="$1"

  python3 - "$instance_id" "$DATASET_NAME" "$DATASET_SUBSET" "$DATASET_SPLIT" "$INSTANCE_FIXTURE_ENV_VAR" <<'PY'
import json
import os
import pathlib
import sys

instance_id, dataset_name, dataset_subset, dataset_split, fixture_env_var = sys.argv[1:]
fixture_path = os.environ.get(fixture_env_var, "").strip()


def load_fixture_records(path: str, env_var_name: str):
    file_path = pathlib.Path(path)
    if not file_path.exists():
        raise RuntimeError(f"{env_var_name} path does not exist: {file_path}")

    text = file_path.read_text(encoding="utf-8")
    if file_path.suffix.lower() == ".jsonl":
        records = []
        for line_number, line in enumerate(text.splitlines(), start=1):
            row = line.strip()
            if not row:
                continue
            try:
                records.append(json.loads(row))
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"invalid JSONL in {file_path} at line {line_number}: {exc.msg}") from exc
        return records

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON in {file_path}: {exc.msg}") from exc

    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        if isinstance(data.get("instances"), list):
            return data["instances"]
        return [data]

    raise RuntimeError(f"unsupported fixture structure in {file_path}; expected JSON object, array, or JSONL")


def lookup_problem_statement(records, target_instance_id: str):
    for record in records:
        if isinstance(record, dict) and record.get("instance_id") == target_instance_id:
            problem_statement = record.get("problem_statement")
            if not isinstance(problem_statement, str) or not problem_statement.strip():
                raise RuntimeError(
                    f"instance '{target_instance_id}' is missing a non-empty problem_statement"
                )
            return problem_statement.strip()
    return None


if fixture_path:
    source = fixture_path
    records = load_fixture_records(fixture_path, fixture_env_var)
    statement = lookup_problem_statement(records, instance_id)
else:
    source = f"{dataset_name} [{dataset_subset}/{dataset_split}]"
    try:
        from datasets import load_dataset
    except Exception as exc:  # pragma: no cover - dependency/runtime environment branch
        raise RuntimeError(
            "python package 'datasets' is required to load SWE-Bench metadata; "
            f"install it or set {fixture_env_var}"
        ) from exc

    dataset = load_dataset(dataset_name, dataset_subset, split=dataset_split)
    statement = lookup_problem_statement(dataset, instance_id)

if statement is None:
    raise RuntimeError(f"instance '{instance_id}' not found in {source}")

sys.stdout.write(statement + "\n")
PY
}

seed_plan_docs() {
  local spec_path="$1"
  local plan_path="$2"
  local instance_id="$3"
  local problem_statement="$4"

  cat > "$spec_path" <<EOF
# Specification: ${instance_id}

## Source Instance
- dataset: ${DATASET_NAME}
- subset: ${DATASET_SUBSET}
- split: ${DATASET_SPLIT}
- instance_id: ${instance_id}

## Problem Statement
${problem_statement}
EOF

  cat > "$plan_path" <<EOF
# Execution Plan: ${instance_id}

## Status
- state: in_progress
- seeded_from: problem_statement
- next_step: run plan prompt and execute-loop in future Phase 2 milestones
EOF
}

write_status_json() {
  local status_path="$1"
  local instance_id="$2"
  local status="$3"
  local failure_reason_code="$4"
  local failure_reason_detail="$5"
  local error_log="$6"

  python3 - "$status_path" "$instance_id" "$status" "$failure_reason_code" "$failure_reason_detail" "$error_log" <<'PY'
import json
import pathlib
import sys

status_path, instance_id, status, failure_reason_code, failure_reason_detail, error_log = sys.argv[1:]

payload = {
    "instance_id": instance_id,
    "status": status,
    "failure_reason_code": None if failure_reason_code == "null" else failure_reason_code,
    "failure_reason_detail": failure_reason_detail,
    "error_log": error_log,
}

path = pathlib.Path(status_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

write_pred_json() {
  local pred_path="$1"
  local instance_id="$2"
  local model_patch="$3"

  python3 - "$pred_path" "$instance_id" "$MODEL_NAME_OR_PATH" "$model_patch" <<'PY'
import json
import pathlib
import sys

pred_path, instance_id, model_name_or_path, model_patch = sys.argv[1:]

payload = {
    "model_name_or_path": model_name_or_path,
    "instance_id": instance_id,
    "model_patch": model_patch,
}

path = pathlib.Path(pred_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

update_manifest() {
  local manifest_path="$1"
  local instance_id="$2"
  local start_time="$3"
  local end_time="$4"
  local status="$5"
  local failure_reason_code="$6"
  local failure_reason_detail="$7"
  local error_log="$8"
  local output_dir="$9"

  python3 - "$manifest_path" "$instance_id" "$start_time" "$end_time" "$status" "$failure_reason_code" "$failure_reason_detail" "$error_log" "$output_dir" "$DATASET_NAME" "$DATASET_SUBSET" "$DATASET_SPLIT" "$CODEX_PROFILE" "$MAX_LOOPS" <<'PY'
import json
import pathlib
import sys

(
    manifest_path,
    instance_id,
    start_time,
    end_time,
    status,
    failure_reason_code,
    failure_reason_detail,
    error_log,
    output_dir,
    dataset_name,
    dataset_subset,
    dataset_split,
    codex_profile,
    max_loops,
) = sys.argv[1:]

manifest_file = pathlib.Path(manifest_path)
manifest_file.parent.mkdir(parents=True, exist_ok=True)

if manifest_file.exists():
    data = json.loads(manifest_file.read_text(encoding="utf-8"))
else:
    data = {
        "dataset": {
            "name": dataset_name,
            "subset": dataset_subset,
            "split": dataset_split,
        },
        "codex": {
            "profile": codex_profile,
            "unattended": True,
        },
        "created_at": start_time,
        "instances": {},
        "counts": {
            "total": 0,
            "success": 0,
            "failed": 0,
            "incomplete": 0,
        },
        "last_invocation": {},
    }

instances = data.setdefault("instances", {})
instances[instance_id] = {
    "instance_id": instance_id,
    "status": status,
    "failure_reason_code": None if failure_reason_code == "null" else failure_reason_code,
    "failure_reason_detail": failure_reason_detail,
    "error_log": error_log,
    "output_dir": output_dir,
    "start_time": start_time,
    "end_time": end_time,
}

counts = {"total": 0, "success": 0, "failed": 0, "incomplete": 0}
for record in instances.values():
    counts["total"] += 1
    record_status = record.get("status")
    if record_status in ("success", "failed", "incomplete"):
        counts[record_status] += 1

data["counts"] = counts
data["updated_at"] = end_time
data["last_invocation"] = {
    "instance_id": instance_id,
    "args": {
        "instance_id": instance_id,
        "output_dir": output_dir,
        "manifest_dir": str(manifest_file.parent),
        "max_loops": int(max_loops),
    },
    "start_time": start_time,
    "end_time": end_time,
}

manifest_file.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id)
      [[ $# -ge 2 ]] || { error "--instance-id requires a value"; exit 2; }
      INSTANCE_ID="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { error "--output-dir requires a value"; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --manifest-dir)
      [[ $# -ge 2 ]] || { error "--manifest-dir requires a value"; exit 2; }
      MANIFEST_DIR="$2"
      shift 2
      ;;
    --max-loops)
      [[ $# -ge 2 ]] || { error "--max-loops requires a value"; exit 2; }
      MAX_LOOPS="$2"
      shift 2
      ;;
    --profile|--codex-profile|--interactive|--claude)
      error "Unsupported option '$1'. This runner hardcodes Codex unattended with profile 'local'."
      exit 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  error "--instance-id is required"
  usage >&2
  exit 2
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  error "--output-dir is required"
  usage >&2
  exit 2
fi

if ! is_positive_integer "$MAX_LOOPS"; then
  error "--max-loops must be a positive integer"
  exit 2
fi

if [[ -z "$MANIFEST_DIR" ]]; then
  MANIFEST_DIR="$OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR" "$MANIFEST_DIR" "$OUTPUT_DIR/logs" "$OUTPUT_DIR/plans/archive" "$OUTPUT_DIR/plans/blocked"

STATUS_PATH="$OUTPUT_DIR/${INSTANCE_ID}.status.json"
PRED_PATH="$OUTPUT_DIR/${INSTANCE_ID}.pred"
PATCH_PATH="$OUTPUT_DIR/${INSTANCE_ID}.patch"
MANIFEST_PATH="$MANIFEST_DIR/run_manifest.json"
SPEC_PATH="$OUTPUT_DIR/plans/SPECIFICATION.md"
PLAN_PATH="$OUTPUT_DIR/plans/EXECUTION_PLAN.md"
METADATA_LOAD_ERR_PATH="$OUTPUT_DIR/logs/instance_metadata_error.log"

START_TIME="$(timestamp_utc)"
ERROR_LOG=""
STATUS="incomplete"
FAILURE_REASON_CODE="incomplete"
FAILURE_REASON_DETAIL="Phase 1 skeleton complete: CLI contracts are implemented; runtime execution loop is pending."
MODEL_PATCH=""
MISSING_PROMPTS=""
PROBLEM_STATEMENT=""

if ! MISSING_PROMPTS="$(collect_missing_prompts)"; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="Missing required runtime prompt file(s) under ralph/prompts"
  ERROR_LOG="$MISSING_PROMPTS"
fi

if [[ "$STATUS" != "failed" ]] && ! PROBLEM_STATEMENT="$(load_instance_problem_statement "$INSTANCE_ID" 2>"$METADATA_LOAD_ERR_PATH")"; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="Failed to load instance metadata/problem_statement"
  if [[ -f "$METADATA_LOAD_ERR_PATH" ]]; then
    ERROR_LOG="$(cat "$METADATA_LOAD_ERR_PATH")"
  fi
fi

if [[ "$STATUS" != "failed" ]]; then
  seed_plan_docs "$SPEC_PATH" "$PLAN_PATH" "$INSTANCE_ID" "$PROBLEM_STATEMENT"
fi

if [[ "$STATUS" != "failed" ]] && ! command -v codex >/dev/null 2>&1; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="codex command not found on PATH"
  ERROR_LOG="codex not found"
fi

# Placeholder command declaration to lock the hard requirement for Phase 2 runtime execution.
CODEX_EXEC_CMD=(codex -p "$CODEX_PROFILE" --dangerously-bypass-approvals-and-sandbox exec)
printf '%s\n' "${CODEX_EXEC_CMD[*]}" > "$OUTPUT_DIR/logs/codex_command.txt"

: > "$PATCH_PATH"
write_pred_json "$PRED_PATH" "$INSTANCE_ID" "$MODEL_PATCH"
END_TIME="$(timestamp_utc)"
write_status_json "$STATUS_PATH" "$INSTANCE_ID" "$STATUS" "$FAILURE_REASON_CODE" "$FAILURE_REASON_DETAIL" "$ERROR_LOG"
update_manifest "$MANIFEST_PATH" "$INSTANCE_ID" "$START_TIME" "$END_TIME" "$STATUS" "$FAILURE_REASON_CODE" "$FAILURE_REASON_DETAIL" "$ERROR_LOG" "$OUTPUT_DIR"

if [[ "$STATUS" == "failed" ]]; then
  echo "start-swebench failed for ${INSTANCE_ID}: ${FAILURE_REASON_DETAIL}" >&2
  exit 1
fi

echo "start-swebench phase1 skeleton complete for ${INSTANCE_ID}; status=${STATUS}"
exit 20
