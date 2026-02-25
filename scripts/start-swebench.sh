#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="SWE-bench/SWE-bench_Multilingual"
DATASET_SUBSET="multilingual"
DATASET_SPLIT="test"
MODEL_NAME_OR_PATH="qwen3-coder-next-FP8,codex,ralph"
CODEX_PROFILE="local"
CODEX_BIN="${CODEX_BIN:-codex}"
MCP_BRIDGE_SERVER_NAME="swebench_docker_exec"
INSTANCE_FIXTURE_ENV_VAR="SWE_BENCH_INSTANCES_FILE"
MAX_LOOPS_DEFAULT=50
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_BRIDGE_SCRIPT="$REPO_ROOT/scripts/mcp-docker-exec-server.py"
PROMPTS_DIR="$REPO_ROOT/ralph/prompts"
REQUIRED_PROMPTS=(plan.md execute.md handoff.md)
IMAGE_REPO_PREFIX="sweb.eval.arm64"
CONTAINER_WORKDIR="${SWE_BENCH_CONTAINER_WORKDIR:-/testbed}"
RUNTIME_CONTAINER_NAME_PREFIX="swebench-runtime-"
RUNTIME_CONTAINER_NAME_MAX_LEN=63

INSTANCE_ID=""
OUTPUT_DIR=""
MANIFEST_DIR=""
MAX_LOOPS="$MAX_LOOPS_DEFAULT"
RUNTIME_CONTAINER_NAME=""

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

sanitize_instance_id_for_container_name() {
  local instance_id="$1"
  local max_suffix_length
  local sanitized

  max_suffix_length="$((RUNTIME_CONTAINER_NAME_MAX_LEN - ${#RUNTIME_CONTAINER_NAME_PREFIX}))"
  if [[ "$max_suffix_length" -lt 1 ]]; then
    echo "runtime container name max length is too small: $RUNTIME_CONTAINER_NAME_MAX_LEN" >&2
    return 1
  fi

  sanitized="$(
    printf '%s' "$instance_id" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9_.-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
  )"

  if [[ -z "$sanitized" ]]; then
    sanitized="instance"
  fi

  sanitized="${sanitized:0:max_suffix_length}"
  sanitized="$(printf '%s' "$sanitized" | sed -E 's/^-+//; s/-+$//')"

  if [[ -z "$sanitized" ]]; then
    sanitized="instance"
  fi

  printf '%s' "$sanitized"
}

runtime_container_name_for_instance() {
  local instance_id="$1"
  local sanitized=""

  if ! sanitized="$(sanitize_instance_id_for_container_name "$instance_id")"; then
    return 1
  fi

  printf '%s%s' "$RUNTIME_CONTAINER_NAME_PREFIX" "$sanitized"
}

cleanup_runtime_container() {
  if [[ -n "$RUNTIME_CONTAINER_NAME" ]]; then
    docker rm -f "$RUNTIME_CONTAINER_NAME" >/dev/null 2>&1 || true
    RUNTIME_CONTAINER_NAME=""
  fi
}

create_runtime_container() {
  local image_ref="$1"
  local output_dir="$2"
  local instance_id="$3"
  local runtime_name=""

  if ! runtime_name="$(runtime_container_name_for_instance "$instance_id")"; then
    echo "failed to resolve runtime container name for instance: $instance_id" >&2
    return 1
  fi

  docker rm -f "$runtime_name" >/dev/null 2>&1 || true

  if ! docker create \
    --name "$runtime_name" \
    --entrypoint /bin/sh \
    --add-host host.docker.internal:host-gateway \
    -v "$output_dir:$output_dir" \
    "$image_ref" \
    -lc "while true; do sleep 3600; done" >/dev/null; then
    echo "failed to create runtime container from image: $image_ref" >&2
    return 1
  fi

  if ! docker start "$runtime_name" >/dev/null; then
    echo "failed to start runtime container: $runtime_name" >&2
    docker rm -f "$runtime_name" >/dev/null 2>&1 || true
    return 1
  fi

  RUNTIME_CONTAINER_NAME="$runtime_name"
  return 0
}

extract_codex_session_id() {
  local log_path="$1"

  if [[ ! -f "$log_path" ]]; then
    return 1
  fi

  awk '
    match($0, /session id:[[:space:]]*[^[:space:]]+/) {
      token = substr($0, RSTART, RLENGTH)
      sub(/^session id:[[:space:]]*/, "", token)
      id = token
    }
    END {
      if (length(id) == 0) {
        exit 1
      }
      print id
    }
  ' "$log_path"
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

seed_spec_doc() {
  local spec_path="$1"
  local problem_statement="$2"

  cat > "$spec_path" <<EOF
## Problem Statement
${problem_statement}
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

toml_quote_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
}

append_codex_config_overrides() {
  local -n codex_cmd_ref="$1"
  local quoted_mcp_script=""
  local quoted_runtime_container_name=""
  local quoted_container_workdir=""
  local mcp_args_value=""

  quoted_mcp_script="$(toml_quote_string "$MCP_BRIDGE_SCRIPT")"
  quoted_runtime_container_name="$(toml_quote_string "$RUNTIME_CONTAINER_NAME")"
  quoted_container_workdir="$(toml_quote_string "$CONTAINER_WORKDIR")"
  mcp_args_value="[$quoted_mcp_script,\"--container-name\",$quoted_runtime_container_name,\"--workdir\",$quoted_container_workdir]"

  codex_cmd_ref+=(
    -c "features.shell_tool=false"
    -c "features.unified_exec=false"
    -c "mcp_servers={}"
    -c "mcp_servers.${MCP_BRIDGE_SERVER_NAME}.command=\"python3\""
    -c "mcp_servers.${MCP_BRIDGE_SERVER_NAME}.args=${mcp_args_value}"
  )
}

run_codex_phase() {
  local phase="$1"
  local pass_index="$2"
  local prompt_path="$3"
  local resume_session_id="${4:-}"
  local phase_log
  local prompt_text
  local -a codex_cmd
  local -a codex_env_vars

  phase_log="$(codex_phase_log_path "$phase")"
  prompt_text="$(render_prompt_template "$prompt_path" "$phase" "$pass_index")"

  if [[ -z "$RUNTIME_CONTAINER_NAME" ]]; then
    echo "runtime container is not initialized before phase: $phase" >&2
    return 1
  fi

  if [[ "$phase" == "handoff" ]]; then
    if [[ -z "$resume_session_id" ]]; then
      echo "handoff phase requires execute session id for resume" >&2
      return 1
    fi
    codex_cmd=(
      "$CODEX_BIN"
      exec
      -p "$CODEX_PROFILE"
      --dangerously-bypass-approvals-and-sandbox
    )
    append_codex_config_overrides codex_cmd
    codex_cmd+=(resume "$resume_session_id" "$prompt_text")
  else
    codex_cmd=(
      "$CODEX_BIN"
      exec
      -p "$CODEX_PROFILE"
      --dangerously-bypass-approvals-and-sandbox
    )
    append_codex_config_overrides codex_cmd
    codex_cmd+=("$prompt_text")
  fi

  printf 'phase=%s pass=%s runtime_container=%s mcp_server=%s cmd=%s exec -p %s --dangerously-bypass-approvals-and-sandbox -c features.shell_tool=false -c features.unified_exec=false -c mcp_servers={} -c mcp_servers.%s.command="python3" -c mcp_servers.%s.args=[%s,"--container-name",%s,"--workdir",%s] <prompt:%s>\n' \
    "$phase" "$pass_index" "$RUNTIME_CONTAINER_NAME" "$MCP_BRIDGE_SERVER_NAME" "$CODEX_BIN" "$CODEX_PROFILE" "$MCP_BRIDGE_SERVER_NAME" "$MCP_BRIDGE_SERVER_NAME" "$(toml_quote_string "$MCP_BRIDGE_SCRIPT")" "$(toml_quote_string "$RUNTIME_CONTAINER_NAME")" "$(toml_quote_string "$CONTAINER_WORKDIR")" "$prompt_path" >> "$OUTPUT_DIR/logs/codex_command.txt"

  codex_env_vars=(
    "SWE_BENCH_RUNTIME_PHASE=$phase"
    "SWE_BENCH_EXECUTE_PASS=$pass_index"
    "SWE_BENCH_INSTANCE_ID=$INSTANCE_ID"
    "SWE_BENCH_OUTPUT_DIR=$OUTPUT_DIR"
    "SWE_BENCH_PLANS_DIR=$PLANS_DIR"
    "SWE_BENCH_SPEC_PATH=$SPEC_PATH"
    "SWE_BENCH_PLAN_PATH=$PLAN_PATH"
    "SWE_BENCH_ARCHIVE_DIR=$ARCHIVE_DIR"
    "SWE_BENCH_BLOCKED_DIR=$BLOCKED_DIR"
    "SWE_BENCH_PATCH_PATH=$PATCH_PATH"
    "SWE_BENCH_IMAGE_REF=$IMAGE_REF"
  )

  env "${codex_env_vars[@]}" "${codex_cmd[@]}" >>"$phase_log" 2>&1
}

replace_prompt_var() {
  local input_text="$1"
  local var_name="$2"
  local var_value="$3"
  local pattern_double_brace="{{${var_name}}}"
  local pattern_curly_dollar="\${${var_name}}"
  local pattern_dollar="\$${var_name}"
  local output_text="$input_text"

  output_text="${output_text//"$pattern_double_brace"/$var_value}"
  output_text="${output_text//"$pattern_curly_dollar"/$var_value}"
  output_text="${output_text//"$pattern_dollar"/$var_value}"
  printf '%s' "$output_text"
}

render_prompt_template() {
  local prompt_path="$1"
  local phase="$2"
  local pass_index="$3"
  local rendered_text

  rendered_text="$(cat "$prompt_path")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_RUNTIME_PHASE" "$phase")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_EXECUTE_PASS" "$pass_index")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_INSTANCE_ID" "$INSTANCE_ID")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_OUTPUT_DIR" "$OUTPUT_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_PLANS_DIR" "$PLANS_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_SPEC_PATH" "$SPEC_PATH")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_PLAN_PATH" "$PLAN_PATH")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_ARCHIVE_DIR" "$ARCHIVE_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_BLOCKED_DIR" "$BLOCKED_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_PATCH_PATH" "$PATCH_PATH")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_IMAGE_REF" "$IMAGE_REF")"
  printf '%s' "$rendered_text"
}

root_plan_state() {
  local has_spec=0
  local has_plan=0

  if [[ -f "$SPEC_PATH" ]]; then
    has_spec=1
  fi

  if [[ -f "$PLAN_PATH" ]]; then
    has_plan=1
  fi

  if [[ "$has_spec" -eq 1 && "$has_plan" -eq 1 ]]; then
    echo "spec_and_plan"
    return 0
  fi

  if [[ "$has_spec" -eq 1 && "$has_plan" -eq 0 ]]; then
    echo "spec_only"
    return 0
  fi

  if [[ "$has_spec" -eq 0 && "$has_plan" -eq 1 ]]; then
    echo "plan_only"
    return 0
  fi

  echo "missing_both"
}

mark_success() {
  STATUS="success"
  FAILURE_REASON_CODE="null"
  FAILURE_REASON_DETAIL=""
  ERROR_LOG=""
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
PLANS_DIR="$OUTPUT_DIR/plans"
SPEC_PATH="$PLANS_DIR/SPECIFICATION.md"
PLAN_PATH="$PLANS_DIR/EXECUTION_PLAN.md"
ARCHIVE_DIR="$PLANS_DIR/archive"
BLOCKED_DIR="$PLANS_DIR/blocked"
ARCHIVE_SPEC_PATH="$ARCHIVE_DIR/SPECIFICATION.md"
ARCHIVE_PLAN_PATH="$ARCHIVE_DIR/EXECUTION_PLAN.md"
BLOCKED_SPEC_PATH="$BLOCKED_DIR/SPECIFICATION.md"
BLOCKED_PLAN_PATH="$BLOCKED_DIR/EXECUTION_PLAN.md"
METADATA_LOAD_ERR_PATH="$OUTPUT_DIR/logs/instance_metadata_error.log"
IMAGE_PRECHECK_ERR_PATH="$OUTPUT_DIR/logs/image_precheck_error.log"
IMAGE_REF="$(instance_image_ref "$INSTANCE_ID")"
PLAN_PROMPT_PATH="$PROMPTS_DIR/plan.md"
EXECUTE_PROMPT_PATH="$PROMPTS_DIR/execute.md"
HANDOFF_PROMPT_PATH="$PROMPTS_DIR/handoff.md"
RUNTIME_ERR_PATH="$OUTPUT_DIR/logs/runtime_error.log"
RUNTIME_CONTAINER_ERR_PATH="$OUTPUT_DIR/logs/runtime_container_error.log"
MCP_BRIDGE_PRECHECK_ERR_PATH="$OUTPUT_DIR/logs/mcp_bridge_precheck_error.log"

START_TIME="$(timestamp_utc)"
ERROR_LOG=""
STATUS="incomplete"
FAILURE_REASON_CODE="incomplete"
FAILURE_REASON_DETAIL="Execute loop budget exhausted without patch."
MODEL_PATCH=""
MISSING_PROMPTS=""
PROBLEM_STATEMENT=""

trap cleanup_runtime_container EXIT

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
  seed_spec_doc "$SPEC_PATH" "$PROBLEM_STATEMENT"
fi

if [[ "$STATUS" != "failed" ]] && ! ensure_docker_available 2>"$IMAGE_PRECHECK_ERR_PATH"; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="docker command not found on PATH"
  if [[ -f "$IMAGE_PRECHECK_ERR_PATH" ]]; then
    ERROR_LOG="$(cat "$IMAGE_PRECHECK_ERR_PATH")"
  fi
fi

if [[ "$STATUS" != "failed" ]] && [[ ! -f "$MCP_BRIDGE_SCRIPT" ]]; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="Missing required MCP bridge script: ${MCP_BRIDGE_SCRIPT}"
  printf 'required MCP bridge script not found: %s\n' "$MCP_BRIDGE_SCRIPT" > "$MCP_BRIDGE_PRECHECK_ERR_PATH"
  if [[ -f "$MCP_BRIDGE_PRECHECK_ERR_PATH" ]]; then
    ERROR_LOG="$(cat "$MCP_BRIDGE_PRECHECK_ERR_PATH")"
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
  if ! create_runtime_container "$IMAGE_REF" "$OUTPUT_DIR" "$INSTANCE_ID" 2>"$RUNTIME_CONTAINER_ERR_PATH"; then
    STATUS="failed"
    FAILURE_REASON_CODE="runtime_error"
    FAILURE_REASON_DETAIL="Failed to create runtime container for image: ${IMAGE_REF}"
    if [[ -f "$RUNTIME_CONTAINER_ERR_PATH" ]]; then
      ERROR_LOG="$(cat "$RUNTIME_CONTAINER_ERR_PATH")"
    fi
  fi
fi

if [[ "$STATUS" != "failed" ]]; then
  : > "$OUTPUT_DIR/logs/codex_command.txt"
fi

: > "$PATCH_PATH"
EXECUTE_PASSES_RUN=0
if [[ "$STATUS" != "failed" ]]; then
  while true; do
    LOOP_STATE="$(root_plan_state)"

    if [[ "$LOOP_STATE" == "spec_only" ]]; then
      if ! run_codex_phase "plan" "0" "$PLAN_PROMPT_PATH" 2>"$RUNTIME_ERR_PATH"; then
        STATUS="failed"
        FAILURE_REASON_CODE="runtime_error"
        FAILURE_REASON_DETAIL="Plan prompt execution failed for ${INSTANCE_ID}."
        if [[ -f "$RUNTIME_ERR_PATH" ]]; then
          ERROR_LOG="$(cat "$RUNTIME_ERR_PATH")"
        fi
        break
      fi

      POST_PLAN_STATE="$(root_plan_state)"
      if [[ "$POST_PLAN_STATE" != "spec_and_plan" ]]; then
        STATUS="failed"
        FAILURE_REASON_CODE="runtime_error"
        FAILURE_REASON_DETAIL="Plan phase ended with invalid planning-doc state (${POST_PLAN_STATE})."
        ERROR_LOG=""
        break
      fi
      continue
    fi

    if [[ "$LOOP_STATE" != "spec_and_plan" ]]; then
      STATUS="failed"
      FAILURE_REASON_CODE="runtime_error"
      FAILURE_REASON_DETAIL="Planning docs are not in root plans directory before execute (${LOOP_STATE})."
      ERROR_LOG=""
      break
    fi

    if [[ "$EXECUTE_PASSES_RUN" -ge "$MAX_LOOPS" ]]; then
      STATUS="incomplete"
      FAILURE_REASON_CODE="incomplete"
      FAILURE_REASON_DETAIL="Planning docs remain in root plans directory after execute budget."
      ERROR_LOG=""
      break
    fi

    pass=$((EXECUTE_PASSES_RUN + 1))
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

    if [[ -s "$PATCH_PATH" ]]; then
      mark_success
      break
    fi

    POST_EXECUTE_STATE="$(root_plan_state)"
    if [[ "$POST_EXECUTE_STATE" == "spec_and_plan" ]]; then
      EXECUTE_SESSION_ID="$(extract_codex_session_id "$(codex_phase_log_path "execute")" || true)"
      if [[ -z "$EXECUTE_SESSION_ID" ]]; then
        STATUS="failed"
        FAILURE_REASON_CODE="runtime_error"
        FAILURE_REASON_DETAIL="Unable to resolve execute session id for handoff resume on pass ${pass} for ${INSTANCE_ID}."
        ERROR_LOG="Missing execute session id in $(codex_phase_log_path "execute")"
        break
      fi

      if ! run_codex_phase "handoff" "$pass" "$HANDOFF_PROMPT_PATH" "$EXECUTE_SESSION_ID" 2>"$RUNTIME_ERR_PATH"; then
        STATUS="failed"
        FAILURE_REASON_CODE="runtime_error"
        FAILURE_REASON_DETAIL="Handoff prompt failed on execute pass ${pass} for ${INSTANCE_ID}."
        if [[ -f "$RUNTIME_ERR_PATH" ]]; then
          ERROR_LOG="$(cat "$RUNTIME_ERR_PATH")"
        fi
        break
      fi
      continue
    fi

    STATUS="failed"
    FAILURE_REASON_CODE="runtime_error"
    FAILURE_REASON_DETAIL="Execute completed without patch and planning docs left root plans directory (${POST_EXECUTE_STATE})."
    ERROR_LOG=""
    break
  done
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
