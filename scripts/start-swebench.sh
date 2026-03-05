#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="SWE-bench/SWE-bench_Multilingual"
DATASET_SUBSET="multilingual"
DATASET_SPLIT="test"
MODEL_NAME_OR_PATH="qwen3-coder-next-FP8,codex,ralph"
CODEX_PROFILE="local"
CODEX_BIN="${CODEX_BIN:-codex}"
PYTHON_BIN="${SWE_BENCH_PYTHON_BIN:-}"
MCP_BRIDGE_SERVER_NAME="swebench_docker_exec"
INSTANCE_FIXTURE_ENV_VAR="SWE_BENCH_INSTANCES_FILE"
MAX_LOOPS_DEFAULT=20
MAX_EXCEPTION_LOOPS_DEFAULT=2
CODEX_PHASE_TIMEOUT_SECONDS_DEFAULT=1800
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEX_HOME_DEFAULT="$REPO_ROOT/config/codex-home"
CODEX_HOME_DIR="${SWE_BENCH_CODEX_HOME:-$CODEX_HOME_DEFAULT}"
if [[ -z "$PYTHON_BIN" ]]; then
  if [[ -x "$REPO_ROOT/venv/bin/python3" ]]; then
    PYTHON_BIN="$REPO_ROOT/venv/bin/python3"
  else
    PYTHON_BIN="python3"
  fi
fi
MCP_BRIDGE_SCRIPT="$REPO_ROOT/scripts/mcp-docker-exec-server.py"
PROMPTS_DIR="$REPO_ROOT/ralph/prompts"
REQUIRED_PROMPTS=(plan.md execute.md exception.md)
IMAGE_REPO_PREFIX="sweb.eval.arm64"
CONTAINER_WORKDIR="${SWE_BENCH_CONTAINER_WORKDIR:-/testbed}"
RUNTIME_CONTAINER_NAME_PREFIX="swebench-runtime-"
RUNTIME_CONTAINER_NAME_MAX_LEN=63

INSTANCE_ID=""
OUTPUT_DIR=""
MANIFEST_DIR=""
MAX_LOOPS="$MAX_LOOPS_DEFAULT"
MAX_EXCEPTION_LOOPS="${SWE_BENCH_MAX_EXCEPTION_LOOPS:-$MAX_EXCEPTION_LOOPS_DEFAULT}"
CODEX_PHASE_TIMEOUT_SECONDS="${SWE_BENCH_CODEX_PHASE_TIMEOUT_SECONDS:-$CODEX_PHASE_TIMEOUT_SECONDS_DEFAULT}"
RUNTIME_CONTAINER_NAME=""
CODEX_CONFIG_PATH=""

usage() {
  cat <<USAGE
Usage: scripts/start-swebench.sh --instance-id <id> --output-dir <path> [options]

Required:
  --instance-id <id>     SWE-Bench instance ID to process
  --output-dir <path>    Per-instance runtime output directory

Options:
  --manifest-dir <path>  Run manifest directory (default: --output-dir)
  --max-loops <n>        Total plan+execute pass budget (default: ${MAX_LOOPS_DEFAULT})
  --max-exception-loops <n>
                         Exception-phase retries when artifact states mismatch (default: ${MAX_EXCEPTION_LOOPS_DEFAULT})
  -h, --help             Show this help message

Behavior:
  - Single-instance only
  - Codex-only unattended contract (hardcoded: codex -p local)
  - Per-phase timeout can be tuned via SWE_BENCH_CODEX_PHASE_TIMEOUT_SECONDS
  - Codex launches with CODEX_HOME from SWE_BENCH_CODEX_HOME (default: config/codex-home)
USAGE
}

error() {
  echo "Error: $*" >&2
}

absolute_path_from_pwd() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
    return 0
  fi
  printf '%s/%s' "$PWD" "$path"
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

ensure_python_available() {
  if [[ "$PYTHON_BIN" == */* ]]; then
    [[ -x "$PYTHON_BIN" ]]
    return
  fi

  command -v "$PYTHON_BIN" >/dev/null 2>&1
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
  local host_output_dir="$2"
  local runtime_output_dir="$3"
  local instance_id="$4"
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
    -v "$host_output_dir:$runtime_output_dir" \
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

load_instance_problem_statement() {
  local instance_id="$1"

  "$PYTHON_BIN" - "$instance_id" "$DATASET_NAME" "$DATASET_SUBSET" "$DATASET_SPLIT" "$INSTANCE_FIXTURE_ENV_VAR" <<'PY'
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


def resolve_dataset_path(dataset_name: str, dataset_subset: str) -> str:
    subset = dataset_subset.strip().lower()
    subset_mapping = {
        "full": "princeton-nlp/SWE-Bench",
        "verified": "princeton-nlp/SWE-Bench_Verified",
        "lite": "princeton-nlp/SWE-Bench_Lite",
        "multimodal": "princeton-nlp/SWE-Bench_Multimodal",
        "multilingual": "swe-bench/SWE-Bench_Multilingual",
    }
    if subset in subset_mapping:
        return subset_mapping[subset]

    normalized_aliases = {
        "swe-bench/swe-bench_multilingual": "swe-bench/SWE-Bench_Multilingual",
    }
    normalized_name = dataset_name.strip().lower()
    return normalized_aliases.get(normalized_name, dataset_name)


if fixture_path:
    source = fixture_path
    records = load_fixture_records(fixture_path, fixture_env_var)
    statement = lookup_problem_statement(records, instance_id)
else:
    resolved_dataset_path = resolve_dataset_path(dataset_name, dataset_subset)
    source = f"{resolved_dataset_path} [{dataset_split}]"
    try:
        from datasets import load_dataset
    except Exception as exc:  # pragma: no cover - dependency/runtime environment branch
        raise RuntimeError(
            "python package 'datasets' is required to load SWE-Bench metadata; "
            f"install it or set {fixture_env_var}"
        ) from exc

    dataset = load_dataset(resolved_dataset_path, split=dataset_split)
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
  local failure_reason_detail_file
  local error_log_file

  failure_reason_detail_file="$(mktemp)"
  error_log_file="$(mktemp)"
  printf '%s' "$failure_reason_detail" > "$failure_reason_detail_file"
  printf '%s' "$error_log" > "$error_log_file"

  if ! "$PYTHON_BIN" - "$status_path" "$instance_id" "$status" "$failure_reason_code" "$failure_reason_detail_file" "$error_log_file" <<'PY'
import json
import pathlib
import sys

status_path, instance_id, status, failure_reason_code, failure_reason_detail_file, error_log_file = sys.argv[1:]
failure_reason_detail = pathlib.Path(failure_reason_detail_file).read_text(encoding="utf-8", errors="replace")
error_log = pathlib.Path(error_log_file).read_text(encoding="utf-8", errors="replace")

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
  then
    rm -f "$failure_reason_detail_file" "$error_log_file"
    return 1
  fi
  rm -f "$failure_reason_detail_file" "$error_log_file"
}

write_pred_json() {
  local pred_path="$1"
  local instance_id="$2"
  local model_patch="$3"
  local model_patch_file

  model_patch_file="$(mktemp)"
  printf '%s' "$model_patch" > "$model_patch_file"

  if ! "$PYTHON_BIN" - "$pred_path" "$instance_id" "$MODEL_NAME_OR_PATH" "$model_patch_file" <<'PY'
import json
import pathlib
import sys

pred_path, instance_id, model_name_or_path, model_patch_file = sys.argv[1:]
model_patch = pathlib.Path(model_patch_file).read_text(encoding="utf-8", errors="replace")

payload = {
    "model_name_or_path": model_name_or_path,
    "instance_id": instance_id,
    "model_patch": model_patch,
}

path = pathlib.Path(pred_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  then
    rm -f "$model_patch_file"
    return 1
  fi
  rm -f "$model_patch_file"
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
  local failure_reason_detail_file
  local error_log_file

  failure_reason_detail_file="$(mktemp)"
  error_log_file="$(mktemp)"
  printf '%s' "$failure_reason_detail" > "$failure_reason_detail_file"
  printf '%s' "$error_log" > "$error_log_file"

  if ! "$PYTHON_BIN" - "$manifest_path" "$instance_id" "$start_time" "$end_time" "$status" "$failure_reason_code" "$failure_reason_detail_file" "$error_log_file" "$output_dir" "$DATASET_NAME" "$DATASET_SUBSET" "$DATASET_SPLIT" "$CODEX_PROFILE" "$MAX_LOOPS" <<'PY'
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
    failure_reason_detail_file,
    error_log_file,
    output_dir,
    dataset_name,
    dataset_subset,
    dataset_split,
    codex_profile,
    max_loops,
) = sys.argv[1:]
failure_reason_detail = pathlib.Path(failure_reason_detail_file).read_text(encoding="utf-8", errors="replace")
error_log = pathlib.Path(error_log_file).read_text(encoding="utf-8", errors="replace")

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
  then
    rm -f "$failure_reason_detail_file" "$error_log_file"
    return 1
  fi
  rm -f "$failure_reason_detail_file" "$error_log_file"
}

phase_failure_context() {
  local phase="$1"
  local pass_index="$2"
  local runtime_container="${RUNTIME_CONTAINER_NAME:-<uninitialized>}"

  printf 'phase=%s pass=%s runtime_container=%s workdir=%s mcp_server=%s' \
    "$phase" "$pass_index" "$runtime_container" "$CONTAINER_WORKDIR" "$MCP_BRIDGE_SERVER_NAME"
}

collect_phase_failure_error_log() {
  local phase="$1"
  local runtime_err_path="$2"
  local phase_log_tail=""
  local combined=""

  if [[ -f "$runtime_err_path" ]] && [[ -s "$runtime_err_path" ]]; then
    combined="$(cat "$runtime_err_path")"
  fi

  if [[ -f "$CODEX_RUN_LOG_PATH" ]] && [[ -s "$CODEX_RUN_LOG_PATH" ]]; then
    phase_log_tail="$(tail -n 200 "$CODEX_RUN_LOG_PATH")"
    if [[ -n "$combined" ]]; then
      combined+=$'\n'
    fi
    combined+="[codex_run.log tail]"$'\n'"${phase_log_tail}"
  fi

  printf '%s' "$combined"
}

set_mcp_phase_failure() {
  local phase="$1"
  local pass_index="$2"
  local message="$3"
  local runtime_err_path="$4"

  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="${message} ($(phase_failure_context "$phase" "$pass_index"))."
  ERROR_LOG="$(collect_phase_failure_error_log "$phase" "$runtime_err_path")"
}

log_phase_warning() {
  local phase="$1"
  local pass_index="$2"
  local message="$3"
  local runtime_err_path="$4"
  local warning_detail=""
  local warning_log_body=""

  warning_detail="${message} ($(phase_failure_context "$phase" "$pass_index"))."
  warning_log_body="$(collect_phase_failure_error_log "$phase" "$runtime_err_path")"

  {
    printf '[%s] %s\n' "$(timestamp_utc)" "$warning_detail"
    if [[ -n "$warning_log_body" ]]; then
      printf '%s\n' "$warning_log_body"
    fi
    printf '\n'
  } >> "$RUNTIME_WARN_PATH"
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
  local loop_index="${4:-$pass_index}"
  local header_title=""
  local prompt_text
  local phase_exit_code=0
  local -a codex_cmd
  local -a codex_env_vars

  prompt_text="$(render_prompt_template "$prompt_path" "$phase" "$pass_index")"

  if [[ -z "$RUNTIME_CONTAINER_NAME" ]]; then
    echo "runtime container is not initialized before phase: $phase" >&2
    return 1
  fi

  codex_cmd=(
    "$CODEX_BIN"
    exec
    -p "$CODEX_PROFILE"
    --dangerously-bypass-approvals-and-sandbox
  )
  append_codex_config_overrides codex_cmd
  codex_cmd+=("$prompt_text")

  printf 'phase=%s pass=%s runtime_container=%s mcp_server=%s cmd=%s exec -p %s --dangerously-bypass-approvals-and-sandbox -c features.shell_tool=false -c features.unified_exec=false -c mcp_servers={} -c mcp_servers.%s.command="python3" -c mcp_servers.%s.args=[%s,"--container-name",%s,"--workdir",%s] <prompt:%s>\n' \
    "$phase" "$pass_index" "$RUNTIME_CONTAINER_NAME" "$MCP_BRIDGE_SERVER_NAME" "$CODEX_BIN" "$CODEX_PROFILE" "$MCP_BRIDGE_SERVER_NAME" "$MCP_BRIDGE_SERVER_NAME" "$(toml_quote_string "$MCP_BRIDGE_SCRIPT")" "$(toml_quote_string "$RUNTIME_CONTAINER_NAME")" "$(toml_quote_string "$CONTAINER_WORKDIR")" "$prompt_path" >> "$OUTPUT_DIR/logs/codex_command.txt"

  codex_env_vars=(
    "CODEX_HOME=$CODEX_HOME_DIR"
    "SWE_BENCH_RUNTIME_PHASE=$phase"
    "SWE_BENCH_EXECUTE_PASS=$pass_index"
    "SWE_BENCH_INSTANCE_ID=$INSTANCE_ID"
    "SWE_BENCH_OUTPUT_DIR=$RUNTIME_OUTPUT_DIR"
    "SWE_BENCH_PLANS_DIR=$RUNTIME_PLANS_DIR"
    "SWE_BENCH_SPEC_PATH=$RUNTIME_SPEC_PATH"
    "SWE_BENCH_PLAN_PATH=$RUNTIME_PLAN_PATH"
    "SWE_BENCH_ARCHIVE_DIR=$RUNTIME_ARCHIVE_DIR"
    "SWE_BENCH_BLOCKED_DIR=$RUNTIME_BLOCKED_DIR"
    "SWE_BENCH_PATCH_PATH=$RUNTIME_PATCH_PATH"
    "SWE_BENCH_CODE_DIR=$CONTAINER_WORKDIR"
    "SWE_BENCH_HOST_OUTPUT_DIR=$OUTPUT_DIR"
    "SWE_BENCH_HOST_PLANS_DIR=$PLANS_DIR"
    "SWE_BENCH_HOST_SPEC_PATH=$SPEC_PATH"
    "SWE_BENCH_HOST_PLAN_PATH=$PLAN_PATH"
    "SWE_BENCH_HOST_ARCHIVE_DIR=$ARCHIVE_DIR"
    "SWE_BENCH_HOST_BLOCKED_DIR=$BLOCKED_DIR"
    "SWE_BENCH_HOST_PATCH_PATH=$PATCH_STAGING_PATH"
    "SWE_BENCH_IMAGE_REF=$IMAGE_REF"
  )

  case "$phase" in
    plan) header_title="Loop #${loop_index} - Plan Mode" ;;
    execute) header_title="Loop #${loop_index} - Execute Mode" ;;
    exception) header_title="Exception #${loop_index}" ;;
    *) header_title="Phase ${phase}" ;;
  esac
  {
    printf '\n=== %s ===\n' "$header_title"
    printf '[%s] phase=%s pass=%s\n' "$(timestamp_utc)" "$phase" "$pass_index"
  } >> "$CODEX_RUN_LOG_PATH"

  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=30s "${CODEX_PHASE_TIMEOUT_SECONDS}s" \
      env "${codex_env_vars[@]}" "${codex_cmd[@]}" 2>&1 | tee -a "$CODEX_RUN_LOG_PATH"
  else
    env "${codex_env_vars[@]}" "${codex_cmd[@]}" 2>&1 | tee -a "$CODEX_RUN_LOG_PATH"
  fi
  phase_exit_code=$?
  set -e

  if [[ "$phase_exit_code" -eq 124 ]]; then
    printf 'codex phase timed out after %ss (phase=%s pass=%s)\n' \
      "$CODEX_PHASE_TIMEOUT_SECONDS" "$phase" "$pass_index" >&2
  fi

  return "$phase_exit_code"
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
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_OUTPUT_DIR" "$RUNTIME_OUTPUT_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_PLANS_DIR" "$RUNTIME_PLANS_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_SPEC_PATH" "$RUNTIME_SPEC_PATH")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_PLAN_PATH" "$RUNTIME_PLAN_PATH")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_ARCHIVE_DIR" "$RUNTIME_ARCHIVE_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_BLOCKED_DIR" "$RUNTIME_BLOCKED_DIR")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_PATCH_PATH" "$RUNTIME_PATCH_PATH")"
  rendered_text="$(replace_prompt_var "$rendered_text" "SWE_BENCH_CODE_DIR" "$CONTAINER_WORKDIR")"
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

doc_location_state() {
  local root_path="$1"
  local archive_path="$2"
  local blocked_path="$3"
  local count=0
  local value=""

  if [[ -f "$root_path" ]]; then
    count=$((count + 1))
    value="root"
  fi
  if [[ -f "$archive_path" ]]; then
    count=$((count + 1))
    value="archive"
  fi
  if [[ -f "$blocked_path" ]]; then
    count=$((count + 1))
    value="blocked"
  fi

  if [[ "$count" -eq 0 ]]; then
    echo "missing"
    return 0
  fi
  if [[ "$count" -eq 1 ]]; then
    echo "$value"
    return 0
  fi
  echo "duplicate"
}

doc_pair_state() {
  local spec_state
  local plan_state
  spec_state="$(doc_location_state "$SPEC_PATH" "$ARCHIVE_SPEC_PATH" "$BLOCKED_SPEC_PATH")"
  plan_state="$(doc_location_state "$PLAN_PATH" "$ARCHIVE_PLAN_PATH" "$BLOCKED_PLAN_PATH")"

  if [[ "$spec_state" == "duplicate" || "$plan_state" == "duplicate" ]]; then
    echo "duplicate"
    return 0
  fi
  if [[ "$spec_state" == "missing" && "$plan_state" == "missing" ]]; then
    echo "missing_both"
    return 0
  fi
  if [[ "$spec_state" == "root" && "$plan_state" == "root" ]]; then
    echo "root_pair"
    return 0
  fi
  if [[ "$spec_state" == "root" && "$plan_state" == "missing" ]]; then
    echo "spec_only_root"
    return 0
  fi
  if [[ "$spec_state" == "missing" && "$plan_state" == "root" ]]; then
    echo "plan_only_root"
    return 0
  fi
  if [[ "$spec_state" == "archive" && "$plan_state" == "archive" ]]; then
    echo "archive_pair"
    return 0
  fi
  if [[ "$spec_state" == "blocked" && "$plan_state" == "blocked" ]]; then
    echo "blocked_pair"
    return 0
  fi
  echo "split_or_partial"
}

effective_patch_path() {
  if [[ -f "$PATCH_PATH" ]]; then
    printf '%s' "$PATCH_PATH"
    return 0
  fi
  if [[ -f "$PATCH_STAGING_PATH" ]]; then
    printf '%s' "$PATCH_STAGING_PATH"
    return 0
  fi
  return 1
}

patch_has_non_whitespace() {
  local patch_path="$1"
  "$PYTHON_BIN" - "$patch_path" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
print("1" if text.strip() else "0")
PY
}

has_non_empty_patch_artifact() {
  local patch_source=""
  if ! patch_source="$(effective_patch_path)"; then
    echo "0"
    return 0
  fi
  patch_has_non_whitespace "$patch_source"
}

finalize_patch_artifact() {
  local patch_source=""
  if ! patch_source="$(effective_patch_path)"; then
    return 1
  fi
  if [[ "$(patch_has_non_whitespace "$patch_source")" != "1" ]]; then
    return 1
  fi
  if [[ "$patch_source" != "$PATCH_PATH" ]]; then
    mv "$patch_source" "$PATCH_PATH"
  fi
  return 0
}

mark_failure() {
  local detail="$1"
  local reason_code="${2:-runtime_error}"
  local error_log="${3:-}"
  STATUS="failed"
  FAILURE_REASON_CODE="$reason_code"
  FAILURE_REASON_DETAIL="$detail"
  ERROR_LOG="$error_log"
}

mark_patch_driven_outcome() {
  local context="$1"
  local has_patch="$2"
  if [[ "$has_patch" == "1" ]]; then
    if ! finalize_patch_artifact; then
      mark_failure "Failed to finalize patch artifact for ${INSTANCE_ID}" "runtime_error" "Unable to finalize patch from ${PATCH_STAGING_PATH} or ${PATCH_PATH}"
      return 0
    fi
    mark_success
    return 0
  fi
  mark_failure "${context}; no non-empty patch artifact."
}

run_exception_phase() {
  local trigger_context="$1"
  local exception_attempt=0
  local state=""
  local has_patch=""

  while [[ "$exception_attempt" -lt "$MAX_EXCEPTION_LOOPS" ]]; do
    exception_attempt=$((exception_attempt + 1))
    EXCEPTION_PASSES_RUN=$((EXCEPTION_PASSES_RUN + 1))

    if ! run_codex_phase "exception" "$EXCEPTION_PASSES_RUN" "$EXCEPTION_PROMPT_PATH" "$exception_attempt" 2>"$RUNTIME_ERR_PATH"; then
      log_phase_warning "exception" "$EXCEPTION_PASSES_RUN" "Exception prompt exited non-zero for ${INSTANCE_ID}; retrying within exception budget" "$RUNTIME_ERR_PATH"
    fi

    state="$(doc_pair_state)"
    has_patch="$(has_non_empty_patch_artifact)"

    if [[ "$state" == "archive_pair" && "$has_patch" == "1" ]]; then
      mark_patch_driven_outcome "Exception resolved to archive+patch (${trigger_context})" "$has_patch"
      return 0
    fi
    if [[ "$state" == "blocked_pair" && "$has_patch" == "1" ]]; then
      # Requested behavior: blocked+patch is a prediction success; leave docs as-is.
      mark_patch_driven_outcome "Exception resolved to blocked+patch (${trigger_context})" "$has_patch"
      return 0
    fi
    if [[ "$state" == "blocked_pair" && "$has_patch" == "0" ]]; then
      mark_failure "Planning docs moved to blocked without patch during exception phase."
      return 0
    fi

    if [[ "$state" == "root_pair" && "$has_patch" == "0" ]]; then
      continue
    fi

    mark_patch_driven_outcome "Exception phase terminal artifact state (${state}; ${trigger_context})" "$has_patch"
    return 0
  done

  state="$(doc_pair_state)"
  has_patch="$(has_non_empty_patch_artifact)"
  mark_patch_driven_outcome "Exception phase exhausted after ${MAX_EXCEPTION_LOOPS} attempt(s) (${state}; ${trigger_context})" "$has_patch"
}

evaluate_artifacts_state() {
  local context="$1"
  local allow_exception="$2"
  local state=""
  local has_patch=""

  state="$(doc_pair_state)"
  has_patch="$(has_non_empty_patch_artifact)"

  if [[ "$state" == "archive_pair" && "$has_patch" == "1" ]]; then
    mark_patch_driven_outcome "Archive+patch detected (${context})" "$has_patch"
    return 0
  fi
  if [[ "$state" == "blocked_pair" && "$has_patch" == "1" ]]; then
    # Requested behavior: blocked+patch is a prediction success; leave docs as-is.
    mark_patch_driven_outcome "Blocked+patch detected (${context})" "$has_patch"
    return 0
  fi
  if [[ "$state" == "blocked_pair" && "$has_patch" == "0" ]]; then
    mark_failure "Planning docs moved to blocked without patch."
    return 0
  fi

  if [[ "$allow_exception" == "1" ]]; then
    if [[ "$state" == "archive_pair" && "$has_patch" == "0" ]]; then
      run_exception_phase "${context}: archive without patch"
      return 0
    fi
    if [[ "$state" == "root_pair" && "$has_patch" == "1" ]]; then
      run_exception_phase "${context}: patch without archived docs"
      return 0
    fi
  fi

  if [[ "$state" == "root_pair" && "$has_patch" == "0" ]]; then
    return 1
  fi
  if [[ "$state" == "spec_only_root" && "$has_patch" == "0" ]]; then
    return 1
  fi

  # Edge/ambiguous states: patch presence decides success/failure, then exit.
  mark_patch_driven_outcome "Terminal edge artifact state (${state}; ${context})" "$has_patch"
  return 0
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
    --max-exception-loops)
      [[ $# -ge 2 ]] || { error "--max-exception-loops requires a value"; exit 2; }
      MAX_EXCEPTION_LOOPS="$2"
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

if ! is_positive_integer "$MAX_EXCEPTION_LOOPS"; then
  error "--max-exception-loops must be a positive integer"
  exit 2
fi

if ! is_positive_integer "$CODEX_PHASE_TIMEOUT_SECONDS"; then
  error "SWE_BENCH_CODEX_PHASE_TIMEOUT_SECONDS must be a positive integer"
  exit 2
fi

if [[ -z "$MANIFEST_DIR" ]]; then
  MANIFEST_DIR="$OUTPUT_DIR"
fi

OUTPUT_DIR="$(absolute_path_from_pwd "$OUTPUT_DIR")"
MANIFEST_DIR="$(absolute_path_from_pwd "$MANIFEST_DIR")"
CODEX_HOME_DIR="$(absolute_path_from_pwd "$CODEX_HOME_DIR")"
CODEX_CONFIG_PATH="$CODEX_HOME_DIR/config.toml"

mkdir -p "$OUTPUT_DIR" "$MANIFEST_DIR" "$OUTPUT_DIR/logs" "$OUTPUT_DIR/plans/archive" "$OUTPUT_DIR/plans/blocked"

STATUS_PATH="$OUTPUT_DIR/${INSTANCE_ID}.status.json"
PRED_PATH="$OUTPUT_DIR/${INSTANCE_ID}.pred"
PATCH_PATH="$OUTPUT_DIR/${INSTANCE_ID}.patch"
PATCH_STAGING_PATH="$OUTPUT_DIR/.${INSTANCE_ID}.patch.tmp"
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
RUNTIME_OUTPUT_DIR="$OUTPUT_DIR"
RUNTIME_PLANS_DIR="$RUNTIME_OUTPUT_DIR/plans"
RUNTIME_SPEC_PATH="$RUNTIME_PLANS_DIR/SPECIFICATION.md"
RUNTIME_PLAN_PATH="$RUNTIME_PLANS_DIR/EXECUTION_PLAN.md"
RUNTIME_ARCHIVE_DIR="$RUNTIME_PLANS_DIR/archive"
RUNTIME_BLOCKED_DIR="$RUNTIME_PLANS_DIR/blocked"
RUNTIME_PATCH_PATH="$RUNTIME_OUTPUT_DIR/.${INSTANCE_ID}.patch.tmp"
METADATA_LOAD_ERR_PATH="$OUTPUT_DIR/logs/instance_metadata_error.log"
IMAGE_PRECHECK_ERR_PATH="$OUTPUT_DIR/logs/image_precheck_error.log"
IMAGE_REF="$(instance_image_ref "$INSTANCE_ID")"
PLAN_PROMPT_PATH="$PROMPTS_DIR/plan.md"
EXECUTE_PROMPT_PATH="$PROMPTS_DIR/execute.md"
EXCEPTION_PROMPT_PATH="$PROMPTS_DIR/exception.md"
RUNTIME_ERR_PATH="$OUTPUT_DIR/logs/runtime_error.log"
RUNTIME_WARN_PATH="$OUTPUT_DIR/logs/runtime_warning.log"
RUNTIME_CONTAINER_ERR_PATH="$OUTPUT_DIR/logs/runtime_container_error.log"
MCP_BRIDGE_PRECHECK_ERR_PATH="$OUTPUT_DIR/logs/mcp_bridge_precheck_error.log"
CODEX_RUN_LOG_PATH="$OUTPUT_DIR/logs/codex_run.log"

START_TIME="$(timestamp_utc)"
ERROR_LOG=""
STATUS="running"
FAILURE_REASON_CODE="runtime_error"
FAILURE_REASON_DETAIL="Phase loop budget exhausted without patch."
MODEL_PATCH=""
MISSING_PROMPTS=""
PROBLEM_STATEMENT=""

: > "$RUNTIME_ERR_PATH"
: > "$RUNTIME_WARN_PATH"

trap cleanup_runtime_container EXIT

if ! MISSING_PROMPTS="$(collect_missing_prompts)"; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="Missing required runtime prompt file(s) under ralph/prompts"
  ERROR_LOG="$MISSING_PROMPTS"
fi

if [[ "$STATUS" != "failed" ]] && ! ensure_python_available; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="Python interpreter unavailable for runner metadata/artifact operations"
  ERROR_LOG="$PYTHON_BIN"
fi

if [[ "$STATUS" != "failed" ]] && [[ ! -f "$CODEX_CONFIG_PATH" ]]; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="Missing codex config.toml under CODEX_HOME"
  ERROR_LOG="$CODEX_CONFIG_PATH"
fi

if [[ "$STATUS" != "failed" ]] && ! PROBLEM_STATEMENT="$(load_instance_problem_statement "$INSTANCE_ID" 2>"$METADATA_LOAD_ERR_PATH")"; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="Failed to load instance metadata/problem_statement"
  if [[ -f "$METADATA_LOAD_ERR_PATH" ]]; then
    ERROR_LOG="$(cat "$METADATA_LOAD_ERR_PATH")"
  fi
fi

if [[ "$STATUS" != "failed" ]] && [[ ! -f "$SPEC_PATH" ]] && [[ ! -f "$ARCHIVE_SPEC_PATH" ]] && [[ ! -f "$BLOCKED_SPEC_PATH" ]]; then
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
  if ! create_runtime_container "$IMAGE_REF" "$OUTPUT_DIR" "$RUNTIME_OUTPUT_DIR" "$INSTANCE_ID" 2>"$RUNTIME_CONTAINER_ERR_PATH"; then
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
  : > "$RUNTIME_WARN_PATH"
fi

# Reset any prior patch artifacts when reusing an output directory.
rm -f "$PATCH_PATH" "$PATCH_STAGING_PATH"
EXECUTE_PASSES_RUN=0
PLAN_PASSES_RUN=0
EXCEPTION_PASSES_RUN=0
TOTAL_PHASE_PASSES_RUN=0
if [[ "$STATUS" != "failed" ]]; then
  while true; do
    if ! evaluate_artifacts_state "pre-phase check" "1"; then
      :
    else
      break
    fi

    if [[ "$TOTAL_PHASE_PASSES_RUN" -ge "$MAX_LOOPS" ]]; then
      mark_failure "Phase pass budget exhausted without patch after ${MAX_LOOPS} plan/execute pass(es)." "runtime_error"
      break
    fi

    LOOP_STATE="$(root_plan_state)"

    if [[ "$LOOP_STATE" == "spec_only" ]]; then
      PLAN_PASSES_RUN=$((PLAN_PASSES_RUN + 1))
      TOTAL_PHASE_PASSES_RUN=$((TOTAL_PHASE_PASSES_RUN + 1))
      if ! run_codex_phase "plan" "$PLAN_PASSES_RUN" "$PLAN_PROMPT_PATH" "$PLAN_PASSES_RUN" 2>"$RUNTIME_ERR_PATH"; then
        log_phase_warning "plan" "$PLAN_PASSES_RUN" "Plan prompt exited non-zero for ${INSTANCE_ID}; continuing within total pass budget" "$RUNTIME_ERR_PATH"
      fi
      continue
    fi

    if [[ "$LOOP_STATE" == "spec_and_plan" ]]; then
      pass=$((EXECUTE_PASSES_RUN + 1))
      EXECUTE_PASSES_RUN="$pass"
      TOTAL_PHASE_PASSES_RUN=$((TOTAL_PHASE_PASSES_RUN + 1))

      if ! run_codex_phase "execute" "$pass" "$EXECUTE_PROMPT_PATH" "$pass" 2>"$RUNTIME_ERR_PATH"; then
        log_phase_warning "execute" "$pass" "Execute prompt exited non-zero for ${INSTANCE_ID}; continuing within total pass budget" "$RUNTIME_ERR_PATH"
      fi
      continue
    fi

    if [[ "$LOOP_STATE" == "plan_only" ]]; then
      mark_failure "Root plan state is plan_only without specification."
      break
    fi

    if [[ "$LOOP_STATE" == "missing_both" ]]; then
      # Missing-both is resolved by artifact policy above; reaching here indicates no patch.
      mark_failure "Both planning docs are missing and no non-empty patch is present."
      break
    fi

    mark_failure "Unexpected root plan state: ${LOOP_STATE}"
    break
  done
fi

if [[ "$STATUS" == "success" ]]; then
  if ! finalize_patch_artifact; then
    mark_failure "Failed to finalize patch artifact for ${INSTANCE_ID}" "runtime_error" "Unable to finalize patch from ${PATCH_STAGING_PATH} or ${PATCH_PATH}"
  fi
fi

if [[ "$STATUS" == "success" ]]; then
  MODEL_PATCH="$(cat "$PATCH_PATH")"
else
  MODEL_PATCH=""
  rm -f "$PATCH_STAGING_PATH" "$PATCH_PATH"
  if [[ -z "$ERROR_LOG" ]] && [[ -f "$RUNTIME_WARN_PATH" ]] && [[ -s "$RUNTIME_WARN_PATH" ]]; then
    ERROR_LOG="$(cat "$RUNTIME_WARN_PATH")"
  fi
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

echo "start-swebench completed for ${INSTANCE_ID}; status=${STATUS}"
exit 1
