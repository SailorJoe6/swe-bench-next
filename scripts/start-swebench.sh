#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="SWE-bench/SWE-bench_Multilingual"
DATASET_SUBSET="multilingual"
DATASET_SPLIT="test"
MODEL_NAME_OR_PATH="qwen3-coder-next-FP8,codex,ralph"
CODEX_PROFILE="local"
CODEX_BIN="${CODEX_BIN:-codex}"
INSTANCE_FIXTURE_ENV_VAR="SWE_BENCH_INSTANCES_FILE"
MAX_LOOPS_DEFAULT=50
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/ralph/prompts"
REQUIRED_PROMPTS=(plan.md execute.md handoff.md)
IMAGE_REPO_PREFIX="sweb.eval.arm64"
CODEX_BOOTSTRAP_BIN_PATH="${CODEX_BOOTSTRAP_BIN_PATH:-/home/sailorjoe6/.cargo/bin/codex}"
CODEX_BOOTSTRAP_CONFIG_PATH="${CODEX_BOOTSTRAP_CONFIG_PATH:-/home/sailorjoe6/.codex/config.toml}"

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

instance_image_ref() {
  local instance_id="$1"
  echo "${IMAGE_REPO_PREFIX}.${instance_id}:latest"
}

ensure_docker_available() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker command not found on PATH" >&2
    return 1
  fi

  return 0
}

check_instance_image_exists() {
  local image_ref="$1"
  docker image inspect "$image_ref" >/dev/null
}

container_has_codex() {
  local image_ref="$1"
  docker run --rm --entrypoint /bin/sh "$image_ref" -lc "command -v codex >/dev/null 2>&1"
}

cleanup_bootstrap_container() {
  local container_id="$1"
  if [[ -n "$container_id" ]]; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
}

bootstrap_codex_into_image() {
  local image_ref="$1"
  local container_id=""

  if [[ ! -x "$CODEX_BOOTSTRAP_BIN_PATH" ]]; then
    echo "codex bootstrap binary is missing or not executable: $CODEX_BOOTSTRAP_BIN_PATH" >&2
    return 1
  fi

  if [[ ! -f "$CODEX_BOOTSTRAP_CONFIG_PATH" ]]; then
    echo "codex bootstrap config is missing: $CODEX_BOOTSTRAP_CONFIG_PATH" >&2
    return 1
  fi

  if ! container_id="$(docker create --entrypoint /bin/sh "$image_ref" -lc "while true; do sleep 3600; done")"; then
    echo "failed to create bootstrap container from image: $image_ref" >&2
    return 1
  fi

  if ! docker start "$container_id" >/dev/null; then
    echo "failed to start bootstrap container: $container_id" >&2
    cleanup_bootstrap_container "$container_id"
    return 1
  fi

  if ! docker exec "$container_id" /bin/sh -lc "mkdir -p /usr/local/bin /root/.codex /home/sailorjoe6/.codex"; then
    echo "failed to prepare codex target directories in container: $container_id" >&2
    cleanup_bootstrap_container "$container_id"
    return 1
  fi

  if ! docker cp "$CODEX_BOOTSTRAP_BIN_PATH" "$container_id:/usr/local/bin/codex"; then
    echo "failed to copy codex binary into container: $container_id" >&2
    cleanup_bootstrap_container "$container_id"
    return 1
  fi

  if ! docker cp "$CODEX_BOOTSTRAP_CONFIG_PATH" "$container_id:/root/.codex/config.toml"; then
    echo "failed to copy codex config into /root/.codex for container: $container_id" >&2
    cleanup_bootstrap_container "$container_id"
    return 1
  fi

  if ! docker cp "$CODEX_BOOTSTRAP_CONFIG_PATH" "$container_id:/home/sailorjoe6/.codex/config.toml"; then
    echo "failed to copy codex config into /home/sailorjoe6/.codex for container: $container_id" >&2
    cleanup_bootstrap_container "$container_id"
    return 1
  fi

  if ! docker exec "$container_id" /bin/sh -lc "chmod +x /usr/local/bin/codex"; then
    echo "failed to mark codex executable in container: $container_id" >&2
    cleanup_bootstrap_container "$container_id"
    return 1
  fi

  if ! docker commit "$container_id" "$image_ref" >/dev/null; then
    echo "failed to commit codex-bootstrapped image: $image_ref" >&2
    cleanup_bootstrap_container "$container_id"
    return 1
  fi

  cleanup_bootstrap_container "$container_id"
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

codex_phase_log_path() {
  local phase="$1"
  echo "$OUTPUT_DIR/logs/codex_${phase}.log"
}

run_codex_phase() {
  local phase="$1"
  local pass_index="$2"
  local prompt_path="$3"
  local phase_log
  local prompt_text

  phase_log="$(codex_phase_log_path "$phase")"
  prompt_text="$(cat "$prompt_path")"
  printf 'phase=%s pass=%s cmd=%s -p %s --dangerously-bypass-approvals-and-sandbox exec <prompt:%s>\n' \
    "$phase" "$pass_index" "$CODEX_BIN" "$CODEX_PROFILE" "$prompt_path" >> "$OUTPUT_DIR/logs/codex_command.txt"

  SWE_BENCH_RUNTIME_PHASE="$phase" \
  SWE_BENCH_EXECUTE_PASS="$pass_index" \
  SWE_BENCH_INSTANCE_ID="$INSTANCE_ID" \
  SWE_BENCH_OUTPUT_DIR="$OUTPUT_DIR" \
  SWE_BENCH_PLANS_DIR="$OUTPUT_DIR/plans" \
  SWE_BENCH_SPEC_PATH="$SPEC_PATH" \
  SWE_BENCH_PLAN_PATH="$PLAN_PATH" \
  SWE_BENCH_ARCHIVE_DIR="$ARCHIVE_DIR" \
  SWE_BENCH_BLOCKED_DIR="$BLOCKED_DIR" \
  SWE_BENCH_PATCH_PATH="$PATCH_PATH" \
    "$CODEX_BIN" -p "$CODEX_PROFILE" --dangerously-bypass-approvals-and-sandbox exec "$prompt_text" >>"$phase_log" 2>&1
}

classify_plan_state() {
  local mode="$1"
  local context="$2"

  if [[ -f "$BLOCKED_SPEC_PATH" || -f "$BLOCKED_PLAN_PATH" ]]; then
    STATUS="failed"
    FAILURE_REASON_CODE="blocked"
    FAILURE_REASON_DETAIL="Planning docs entered blocked state (${context})."
    ERROR_LOG=""
    return 0
  fi

  if [[ -f "$ARCHIVE_SPEC_PATH" && -f "$ARCHIVE_PLAN_PATH" ]]; then
    if [[ -s "$PATCH_PATH" ]]; then
      STATUS="success"
      FAILURE_REASON_CODE="null"
      FAILURE_REASON_DETAIL=""
      ERROR_LOG=""
    else
      STATUS="incomplete"
      FAILURE_REASON_CODE="incomplete"
      FAILURE_REASON_DETAIL="Planning docs archived but patch output is empty (${context})."
      ERROR_LOG=""
    fi
    return 0
  fi

  if [[ "$mode" == "loop" ]] && ([[ -f "$SPEC_PATH" ]] || [[ -f "$PLAN_PATH" ]]); then
    return 1
  fi

  STATUS="incomplete"
  FAILURE_REASON_CODE="incomplete"
  if [[ -f "$SPEC_PATH" || -f "$PLAN_PATH" ]]; then
    FAILURE_REASON_DETAIL="Planning docs remain in root plans directory after execute budget (${context})."
  else
    FAILURE_REASON_DETAIL="Planning docs were not found in archive/blocked/root at classification time (${context})."
  fi
  ERROR_LOG=""
  return 0
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
ARCHIVE_DIR="$OUTPUT_DIR/plans/archive"
BLOCKED_DIR="$OUTPUT_DIR/plans/blocked"
ARCHIVE_SPEC_PATH="$ARCHIVE_DIR/SPECIFICATION.md"
ARCHIVE_PLAN_PATH="$ARCHIVE_DIR/EXECUTION_PLAN.md"
BLOCKED_SPEC_PATH="$BLOCKED_DIR/SPECIFICATION.md"
BLOCKED_PLAN_PATH="$BLOCKED_DIR/EXECUTION_PLAN.md"
METADATA_LOAD_ERR_PATH="$OUTPUT_DIR/logs/instance_metadata_error.log"
IMAGE_PRECHECK_ERR_PATH="$OUTPUT_DIR/logs/image_precheck_error.log"
CODEX_BOOTSTRAP_ERR_PATH="$OUTPUT_DIR/logs/codex_bootstrap_error.log"
IMAGE_REF="$(instance_image_ref "$INSTANCE_ID")"
PLAN_PROMPT_PATH="$PROMPTS_DIR/plan.md"
EXECUTE_PROMPT_PATH="$PROMPTS_DIR/execute.md"
HANDOFF_PROMPT_PATH="$PROMPTS_DIR/handoff.md"
RUNTIME_ERR_PATH="$OUTPUT_DIR/logs/runtime_error.log"

START_TIME="$(timestamp_utc)"
ERROR_LOG=""
STATUS="incomplete"
FAILURE_REASON_CODE="incomplete"
FAILURE_REASON_DETAIL="Planning docs remain in root plans directory after execute budget."
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

if [[ "$STATUS" != "failed" ]] && ! ensure_docker_available 2>"$IMAGE_PRECHECK_ERR_PATH"; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="docker command not found on PATH"
  if [[ -f "$IMAGE_PRECHECK_ERR_PATH" ]]; then
    ERROR_LOG="$(cat "$IMAGE_PRECHECK_ERR_PATH")"
  fi
fi

if [[ "$STATUS" != "failed" ]] && ! check_instance_image_exists "$IMAGE_REF" 2>"$IMAGE_PRECHECK_ERR_PATH"; then
  STATUS="failed"
  FAILURE_REASON_CODE="missing_image"
  FAILURE_REASON_DETAIL="Missing required instance image: ${IMAGE_REF}"
  if [[ -f "$IMAGE_PRECHECK_ERR_PATH" ]]; then
    ERROR_LOG="$(cat "$IMAGE_PRECHECK_ERR_PATH")"
  fi
fi

if [[ "$STATUS" != "failed" ]]; then
  set +e
  container_has_codex "$IMAGE_REF" 2>"$IMAGE_PRECHECK_ERR_PATH"
  CODEX_CHECK_EXIT="$?"
  set -e

  if [[ "$CODEX_CHECK_EXIT" -eq 1 ]]; then
    if ! bootstrap_codex_into_image "$IMAGE_REF" 2>"$CODEX_BOOTSTRAP_ERR_PATH"; then
      STATUS="failed"
      FAILURE_REASON_CODE="codex_bootstrap_failed"
      FAILURE_REASON_DETAIL="Failed to bootstrap codex in image: ${IMAGE_REF}"
      if [[ -f "$CODEX_BOOTSTRAP_ERR_PATH" ]]; then
        ERROR_LOG="$(cat "$CODEX_BOOTSTRAP_ERR_PATH")"
      else
        ERROR_LOG="codex bootstrap command failed for ${IMAGE_REF}"
      fi
    else
      set +e
      container_has_codex "$IMAGE_REF" 2>"$IMAGE_PRECHECK_ERR_PATH"
      CODEX_CHECK_EXIT="$?"
      set -e
      if [[ "$CODEX_CHECK_EXIT" -ne 0 ]]; then
        STATUS="failed"
        FAILURE_REASON_CODE="codex_bootstrap_failed"
        FAILURE_REASON_DETAIL="Codex still unavailable after bootstrap for image: ${IMAGE_REF}"
        if [[ -f "$IMAGE_PRECHECK_ERR_PATH" ]]; then
          ERROR_LOG="$(cat "$IMAGE_PRECHECK_ERR_PATH")"
        else
          ERROR_LOG="codex not detected after bootstrap for ${IMAGE_REF}"
        fi
      fi
    fi
  elif [[ "$CODEX_CHECK_EXIT" -ne 0 ]]; then
    STATUS="failed"
    FAILURE_REASON_CODE="runtime_error"
    FAILURE_REASON_DETAIL="Failed while checking codex availability in image: ${IMAGE_REF}"
    if [[ -f "$IMAGE_PRECHECK_ERR_PATH" ]]; then
      ERROR_LOG="$(cat "$IMAGE_PRECHECK_ERR_PATH")"
    fi
  fi
fi

if [[ "$STATUS" != "failed" ]]; then
  : > "$OUTPUT_DIR/logs/codex_command.txt"
fi

: > "$PATCH_PATH"
EXECUTE_PASSES_RUN=0
if [[ "$STATUS" != "failed" ]]; then
  if ! run_codex_phase "plan" "0" "$PLAN_PROMPT_PATH" 2>"$RUNTIME_ERR_PATH"; then
    STATUS="failed"
    FAILURE_REASON_CODE="runtime_error"
    FAILURE_REASON_DETAIL="Plan prompt execution failed for ${INSTANCE_ID}."
    if [[ -f "$RUNTIME_ERR_PATH" ]]; then
      ERROR_LOG="$(cat "$RUNTIME_ERR_PATH")"
    fi
  fi
fi

if [[ "$STATUS" != "failed" ]] && ! classify_plan_state "loop" "after_plan"; then
  for ((pass=1; pass<=MAX_LOOPS; pass++)); do
    EXECUTE_PASSES_RUN="$pass"

    if ! run_codex_phase "execute" "$pass" "$EXECUTE_PROMPT_PATH" 2>"$RUNTIME_ERR_PATH"; then
      STATUS="failed"
      FAILURE_REASON_CODE="runtime_error"
      FAILURE_REASON_DETAIL="Execute prompt failed on pass ${pass} for ${INSTANCE_ID}."
      if [[ -f "$RUNTIME_ERR_PATH" ]]; then
        ERROR_LOG="$(cat "$RUNTIME_ERR_PATH")"
      fi
      break
    fi

    if ! run_codex_phase "handoff" "$pass" "$HANDOFF_PROMPT_PATH" 2>"$RUNTIME_ERR_PATH"; then
      STATUS="failed"
      FAILURE_REASON_CODE="runtime_error"
      FAILURE_REASON_DETAIL="Handoff prompt failed on execute pass ${pass} for ${INSTANCE_ID}."
      if [[ -f "$RUNTIME_ERR_PATH" ]]; then
        ERROR_LOG="$(cat "$RUNTIME_ERR_PATH")"
      fi
      break
    fi

    if classify_plan_state "loop" "after_execute_pass_${pass}"; then
      break
    fi
  done
fi

if [[ "$STATUS" == "incomplete" && "$FAILURE_REASON_CODE" == "incomplete" ]]; then
  classify_plan_state "final" "max_loops_${MAX_LOOPS}_execute_passes_${EXECUTE_PASSES_RUN}" || true
fi

if [[ "$STATUS" == "success" ]]; then
  MODEL_PATCH="$(cat "$PATCH_PATH")"
else
  MODEL_PATCH=""
fi

write_pred_json "$PRED_PATH" "$INSTANCE_ID" "$MODEL_PATCH"
END_TIME="$(timestamp_utc)"
write_status_json "$STATUS_PATH" "$INSTANCE_ID" "$STATUS" "$FAILURE_REASON_CODE" "$FAILURE_REASON_DETAIL" "$ERROR_LOG"
update_manifest "$MANIFEST_PATH" "$INSTANCE_ID" "$START_TIME" "$END_TIME" "$STATUS" "$FAILURE_REASON_CODE" "$FAILURE_REASON_DETAIL" "$ERROR_LOG" "$OUTPUT_DIR"

if [[ "$STATUS" == "failed" ]]; then
  echo "start-swebench failed for ${INSTANCE_ID}: ${FAILURE_REASON_DETAIL}" >&2
  exit 1
fi

if [[ "$STATUS" == "success" ]]; then
  echo "start-swebench completed for ${INSTANCE_ID}; status=success"
  exit 0
fi

echo "start-swebench completed for ${INSTANCE_ID}; status=incomplete"
exit 20
