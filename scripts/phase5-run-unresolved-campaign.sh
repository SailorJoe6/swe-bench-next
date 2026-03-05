#!/usr/bin/env bash
set -euo pipefail

MAX_LOOPS_DEFAULT=20
MAX_EXCEPTION_LOOPS_DEFAULT=2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
START_SCRIPT="$SCRIPT_DIR/start-swebench.sh"
EVAL_RUNNER_SCRIPT="$SCRIPT_DIR/phase5-run-evals-sequential.sh"
DEFAULT_CAMPAIGN_ROOT="$REPO_ROOT/results/phase5/unresolved-campaign/current"

CAMPAIGN_ROOT=""
TARGETS_FILE=""
MAX_LOOPS="$MAX_LOOPS_DEFAULT"
MAX_EXCEPTION_LOOPS="$MAX_EXCEPTION_LOOPS_DEFAULT"
RETRY_ALL=0
CONTAINER_FIX_ID=""
IMMEDIATE_EVAL=0

usage() {
  cat <<USAGE
Usage: scripts/phase5-run-unresolved-campaign.sh [options]

Options:
  --campaign-root <path>  Campaign run root containing targets/state/reports
                          (default: $DEFAULT_CAMPAIGN_ROOT)
  --targets-file <path>   Target instance list (default: <campaign-root>/targets/unresolved_ids.txt)
  --max-loops <n>         Total plan+execute pass budget per instance (default: ${MAX_LOOPS_DEFAULT})
  --max-exception-loops <n>
                          Exception-phase retry budget per instance (default: ${MAX_EXCEPTION_LOOPS_DEFAULT})
  --retry-all             Re-run all targets even if a terminal prediction attempt exists
  --container-fix-id <id> Link appended attempts to a recorded container fix ID
  --immediate-eval        Evaluate each non-empty patch before advancing to next instance
  -h, --help              Show this help message

Behavior:
  - Runs one target instance at a time in foreground (blocking per instance)
  - Delegates each prediction attempt to scripts/start-swebench.sh
  - Appends one row per attempt to state/attempts.jsonl
  - Updates state/instance_latest.json for resume
  - Skips terminal instances by default (success|failed|incomplete) unless --retry-all is set
  - Optional same-pass mode (--immediate-eval) runs scripts/phase5-run-evals-sequential.sh
    for the just-completed instance only, so prediction->evaluation happens before next instance
USAGE
}

error() {
  echo "Error: $*" >&2
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
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

collect_target_ids() {
  local targets_path="$1"
  python3 - "$targets_path" <<'PY'
import pathlib
import sys

targets_path = pathlib.Path(sys.argv[1])
if not targets_path.exists():
    raise SystemExit(f"targets file not found: {targets_path}")

ids = []
seen = set()
for raw_line in targets_path.read_text(encoding="utf-8").splitlines():
    value = raw_line.strip()
    if not value or value.startswith("#"):
        continue
    if value in seen:
        continue
    seen.add(value)
    ids.append(value)

if not ids:
    raise SystemExit(f"no target instance IDs found in {targets_path}")

for instance_id in ids:
    print(instance_id)
PY
}

should_skip_instance() {
  local latest_path="$1"
  local instance_id="$2"
  python3 - "$latest_path" "$instance_id" <<'PY'
import json
import pathlib
import sys

latest_path = pathlib.Path(sys.argv[1])
instance_id = sys.argv[2]

if not latest_path.exists():
    print("run")
    raise SystemExit(0)

try:
    payload = json.loads(latest_path.read_text(encoding="utf-8"))
except Exception:
    print("run")
    raise SystemExit(0)

if not isinstance(payload, dict):
    print("run")
    raise SystemExit(0)

entry = payload.get(instance_id)
if not isinstance(entry, dict):
    print("run")
    raise SystemExit(0)

prediction_status = entry.get("prediction_status")
if prediction_status in {"success", "failed", "incomplete"}:
    print("skip")
else:
    print("run")
PY
}

read_latest_eval_state() {
  local latest_path="$1"
  local instance_id="$2"
  python3 - "$latest_path" "$instance_id" <<'PY'
import json
import pathlib
import sys

latest_path = pathlib.Path(sys.argv[1])
instance_id = sys.argv[2]

if not latest_path.exists():
    print("not_run")
    print("infra_unclassified")
    raise SystemExit(0)

try:
    payload = json.loads(latest_path.read_text(encoding="utf-8"))
except Exception:
    payload = {}

if not isinstance(payload, dict):
    payload = {}

entry = payload.get(instance_id)
if not isinstance(entry, dict):
    print("not_run")
    print("infra_unclassified")
    raise SystemExit(0)

evaluation_result = entry.get("evaluation_result")
if not isinstance(evaluation_result, str) or not evaluation_result:
    evaluation_result = "not_run"

classification = entry.get("classification")
if not isinstance(classification, str) or not classification:
    classification = "infra_unclassified"

print(evaluation_result)
print(classification)
PY
}

record_attempt() {
  local attempts_path="$1"
  local latest_path="$2"
  local instance_id="$3"
  local attempt_started_at="$4"
  local attempt_finished_at="$5"
  local invocation_exit_code="$6"
  local instance_output_dir="$7"
  local pred_path="$8"
  local patch_path="$9"
  local status_path="${10}"
  local container_fix_id="${11}"

  python3 - "$attempts_path" "$latest_path" "$instance_id" "$attempt_started_at" "$attempt_finished_at" "$invocation_exit_code" "$instance_output_dir" "$pred_path" "$patch_path" "$status_path" "$container_fix_id" <<'PY'
import json
import pathlib
import sys

(
    attempts_path_raw,
    latest_path_raw,
    instance_id,
    attempt_started_at,
    attempt_finished_at,
    invocation_exit_code_raw,
    instance_output_dir,
    pred_path_raw,
    patch_path_raw,
    status_path_raw,
    container_fix_id_raw,
) = sys.argv[1:]

attempts_path = pathlib.Path(attempts_path_raw)
latest_path = pathlib.Path(latest_path_raw)
pred_path = pathlib.Path(pred_path_raw)
patch_path = pathlib.Path(patch_path_raw)
status_path = pathlib.Path(status_path_raw)
invocation_exit_code = int(invocation_exit_code_raw)

status_payload = {}
if status_path.exists():
    try:
        decoded = json.loads(status_path.read_text(encoding="utf-8"))
        if isinstance(decoded, dict):
            status_payload = decoded
    except Exception:
        status_payload = {}

status_value = status_payload.get("status")
if status_value not in {"success", "failed", "incomplete"}:
    if invocation_exit_code == 0:
        status_value = "success"
    elif invocation_exit_code == 20:
        status_value = "incomplete"
    else:
        status_value = "failed"

failure_reason_code = status_payload.get("failure_reason_code")
if not isinstance(failure_reason_code, str):
    failure_reason_code = None

failure_reason_detail = status_payload.get("failure_reason_detail")
if not isinstance(failure_reason_detail, str):
    failure_reason_detail = ""

error_log = status_payload.get("error_log")
if not isinstance(error_log, str):
    error_log = ""

pred_path_value = str(pred_path) if pred_path.exists() else ""
patch_path_value = str(patch_path) if patch_path.exists() else ""
patch_non_empty = bool(patch_path.exists() and patch_path.stat().st_size > 0)

attempt_index = 0
if attempts_path.exists():
    for raw_line in attempts_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and row.get("instance_id") == instance_id:
            attempt_index += 1
attempt_id = f"{instance_id}-attempt-{attempt_index + 1:03d}"

notes = f"prediction delegated to start-swebench.sh (exit_code={invocation_exit_code})"
if not pred_path_value:
    notes += "; prediction artifact missing"
if not patch_non_empty:
    notes += "; patch is empty or missing"
if container_fix_id_raw:
    notes += f"; container_fix_id={container_fix_id_raw}"

record = {
    "instance_id": instance_id,
    "attempt_id": attempt_id,
    "attempt_started_at": attempt_started_at,
    "attempt_finished_at": attempt_finished_at,
    "prediction": {
        "status": status_value,
        "patch_path": patch_path_value,
        "pred_path": pred_path_value,
        "patch_non_empty": patch_non_empty,
        "failure_reason_code": failure_reason_code,
        "failure_reason_detail": failure_reason_detail,
        "error_log": error_log,
        "instance_output_dir": instance_output_dir,
    },
    "evaluation": {
        "executed": False,
        "result": "not_run",
    },
    "classification": "infra_unclassified",
    "container_fix_id": container_fix_id_raw or None,
    "notes": notes,
}

attempts_path.parent.mkdir(parents=True, exist_ok=True)
with attempts_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":")) + "\n")

if latest_path.exists():
    try:
        latest_payload = json.loads(latest_path.read_text(encoding="utf-8"))
    except Exception:
        latest_payload = {}
else:
    latest_payload = {}

if not isinstance(latest_payload, dict):
    latest_payload = {}

latest_payload[instance_id] = {
    "instance_id": instance_id,
    "attempt_id": attempt_id,
    "attempt_finished_at": attempt_finished_at,
    "prediction_status": status_value,
    "patch_non_empty": patch_non_empty,
    "evaluation_result": "not_run",
    "classification": "infra_unclassified",
    "container_fix_id": container_fix_id_raw or None,
}

latest_path.parent.mkdir(parents=True, exist_ok=True)
latest_path.write_text(json.dumps(latest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

print(attempt_id)
print(status_value)
print("true" if patch_non_empty else "false")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaign-root)
      [[ $# -ge 2 ]] || { error "--campaign-root requires a value"; exit 2; }
      CAMPAIGN_ROOT="$2"
      shift 2
      ;;
    --targets-file)
      [[ $# -ge 2 ]] || { error "--targets-file requires a value"; exit 2; }
      TARGETS_FILE="$2"
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
    --retry-all)
      RETRY_ALL=1
      shift
      ;;
    --container-fix-id)
      [[ $# -ge 2 ]] || { error "--container-fix-id requires a value"; exit 2; }
      CONTAINER_FIX_ID="$2"
      shift 2
      ;;
    --immediate-eval)
      IMMEDIATE_EVAL=1
      shift
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

if [[ -z "$CAMPAIGN_ROOT" ]]; then
  CAMPAIGN_ROOT="$DEFAULT_CAMPAIGN_ROOT"
fi

if ! is_positive_integer "$MAX_LOOPS"; then
  error "--max-loops must be a positive integer"
  exit 2
fi

if ! is_positive_integer "$MAX_EXCEPTION_LOOPS"; then
  error "--max-exception-loops must be a positive integer"
  exit 2
fi

if [[ ! -x "$START_SCRIPT" ]]; then
  error "start runner not found or not executable: $START_SCRIPT"
  exit 1
fi

if [[ "$IMMEDIATE_EVAL" -eq 1 && ! -x "$EVAL_RUNNER_SCRIPT" ]]; then
  error "eval runner not found or not executable: $EVAL_RUNNER_SCRIPT"
  exit 1
fi

CAMPAIGN_ROOT="$(absolute_path_from_pwd "$CAMPAIGN_ROOT")"
if [[ -z "$TARGETS_FILE" ]]; then
  TARGETS_FILE="$CAMPAIGN_ROOT/targets/unresolved_ids.txt"
else
  TARGETS_FILE="$(absolute_path_from_pwd "$TARGETS_FILE")"
fi

STATE_DIR="$CAMPAIGN_ROOT/state"
REPORT_DIR="$CAMPAIGN_ROOT/reports"
INSTANCES_DIR="$CAMPAIGN_ROOT/instances"
ATTEMPTS_PATH="$STATE_DIR/attempts.jsonl"
LATEST_PATH="$STATE_DIR/instance_latest.json"
RUN_LOG_PATH="$REPORT_DIR/run_unresolved_campaign.log"

mkdir -p "$STATE_DIR" "$REPORT_DIR" "$INSTANCES_DIR"
touch "$ATTEMPTS_PATH"
if [[ ! -f "$LATEST_PATH" ]]; then
  printf '{}\n' > "$LATEST_PATH"
fi
touch "$RUN_LOG_PATH"

if ! mapfile -t INSTANCE_IDS < <(collect_target_ids "$TARGETS_FILE"); then
  error "Failed to load campaign targets from: $TARGETS_FILE"
  exit 1
fi

if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
  error "No target IDs resolved from: $TARGETS_FILE"
  exit 1
fi

ATTEMPTED_COUNT=0
SKIPPED_COUNT=0
SUCCESS_COUNT=0
FAILED_COUNT=0
INCOMPLETE_COUNT=0
EVAL_ATTEMPTED_COUNT=0
EVAL_SKIPPED_EMPTY_PATCH_COUNT=0
EVAL_RESOLVED_COUNT=0
EVAL_UNRESOLVED_COUNT=0
EVAL_ERROR_COUNT=0

IMMEDIATE_EVAL_TARGETS_FILE=""
if [[ "$IMMEDIATE_EVAL" -eq 1 ]]; then
  IMMEDIATE_EVAL_TARGETS_FILE="$(mktemp "$STATE_DIR/immediate-eval-target.XXXXXX.txt")"
  cleanup_immediate_eval_targets_file() {
    rm -f "$IMMEDIATE_EVAL_TARGETS_FILE"
  }
  trap cleanup_immediate_eval_targets_file EXIT
fi

for instance_id in "${INSTANCE_IDS[@]}"; do
  if [[ "$RETRY_ALL" -ne 1 ]]; then
    skip_decision="$(should_skip_instance "$LATEST_PATH" "$instance_id")"
    if [[ "$skip_decision" == "skip" ]]; then
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      printf '[%s] skip instance=%s reason=terminal_attempt_exists\n' "$(timestamp_utc)" "$instance_id" >> "$RUN_LOG_PATH"
      continue
    fi
  fi

  ATTEMPTED_COUNT=$((ATTEMPTED_COUNT + 1))
  instance_output_dir="$INSTANCES_DIR/$instance_id"
  mkdir -p "$instance_output_dir"

  attempt_started_at="$(timestamp_utc)"

  set +e
  "$START_SCRIPT" \
    --instance-id "$instance_id" \
    --output-dir "$instance_output_dir" \
    --manifest-dir "$CAMPAIGN_ROOT" \
    --max-loops "$MAX_LOOPS" \
    --max-exception-loops "$MAX_EXCEPTION_LOOPS" >> "$RUN_LOG_PATH" 2>&1
  invocation_exit_code="$?"
  set -e

  attempt_finished_at="$(timestamp_utc)"
  pred_path="$instance_output_dir/${instance_id}.pred"
  patch_path="$instance_output_dir/${instance_id}.patch"
  status_path="$instance_output_dir/${instance_id}.status.json"

  mapfile -t attempt_result < <(
    record_attempt \
      "$ATTEMPTS_PATH" \
      "$LATEST_PATH" \
      "$instance_id" \
      "$attempt_started_at" \
      "$attempt_finished_at" \
      "$invocation_exit_code" \
      "$instance_output_dir" \
      "$pred_path" \
      "$patch_path" \
      "$status_path" \
      "$CONTAINER_FIX_ID"
  )

  attempt_id="${attempt_result[0]:-}"
  prediction_status="${attempt_result[1]:-failed}"
  patch_non_empty="${attempt_result[2]:-false}"

  case "$prediction_status" in
    success)
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      ;;
    failed)
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ;;
    incomplete)
      INCOMPLETE_COUNT=$((INCOMPLETE_COUNT + 1))
      ;;
    *)
      FAILED_COUNT=$((FAILED_COUNT + 1))
      prediction_status="failed"
      ;;
  esac

  printf '[%s] attempt=%s instance=%s prediction_status=%s exit_code=%s\n' \
    "$(timestamp_utc)" "$attempt_id" "$instance_id" "$prediction_status" "$invocation_exit_code" >> "$RUN_LOG_PATH"

  if [[ "$IMMEDIATE_EVAL" -eq 1 ]]; then
    if [[ "$patch_non_empty" != "true" ]]; then
      EVAL_SKIPPED_EMPTY_PATCH_COUNT=$((EVAL_SKIPPED_EMPTY_PATCH_COUNT + 1))
      printf '[%s] immediate_eval skip instance=%s attempt=%s reason=patch_empty_or_missing\n' \
        "$(timestamp_utc)" "$instance_id" "$attempt_id" >> "$RUN_LOG_PATH"
      continue
    fi

    EVAL_ATTEMPTED_COUNT=$((EVAL_ATTEMPTED_COUNT + 1))
    printf '%s\n' "$instance_id" > "$IMMEDIATE_EVAL_TARGETS_FILE"

    set +e
    "$EVAL_RUNNER_SCRIPT" \
      --campaign-root "$CAMPAIGN_ROOT" \
      --targets-file "$IMMEDIATE_EVAL_TARGETS_FILE" >> "$RUN_LOG_PATH" 2>&1
    eval_runner_exit_code="$?"
    set -e

    mapfile -t eval_state < <(read_latest_eval_state "$LATEST_PATH" "$instance_id")
    evaluation_result="${eval_state[0]:-not_run}"
    classification="${eval_state[1]:-infra_unclassified}"

    case "$evaluation_result" in
      resolved)
        EVAL_RESOLVED_COUNT=$((EVAL_RESOLVED_COUNT + 1))
        ;;
      unresolved)
        EVAL_UNRESOLVED_COUNT=$((EVAL_UNRESOLVED_COUNT + 1))
        ;;
      eval_error)
        EVAL_ERROR_COUNT=$((EVAL_ERROR_COUNT + 1))
        ;;
      *)
        if [[ "$eval_runner_exit_code" -ne 0 ]]; then
          evaluation_result="eval_error"
          classification="infra_unclassified"
          EVAL_ERROR_COUNT=$((EVAL_ERROR_COUNT + 1))
        fi
        ;;
    esac

    printf '[%s] immediate_eval instance=%s attempt=%s eval_result=%s classification=%s exit_code=%s\n' \
      "$(timestamp_utc)" "$instance_id" "$attempt_id" "$evaluation_result" "$classification" "$eval_runner_exit_code" >> "$RUN_LOG_PATH"
  fi
done

printf 'campaign_root=%s targets_file=%s total=%s attempted=%s skipped=%s success=%s failed=%s incomplete=%s immediate_eval=%s eval_attempted=%s eval_skipped_empty_patch=%s eval_resolved=%s eval_unresolved=%s eval_error=%s attempts_file=%s latest_file=%s run_log=%s\n' \
  "$CAMPAIGN_ROOT" "$TARGETS_FILE" "${#INSTANCE_IDS[@]}" "$ATTEMPTED_COUNT" "$SKIPPED_COUNT" \
  "$SUCCESS_COUNT" "$FAILED_COUNT" "$INCOMPLETE_COUNT" "$IMMEDIATE_EVAL" "$EVAL_ATTEMPTED_COUNT" "$EVAL_SKIPPED_EMPTY_PATCH_COUNT" \
  "$EVAL_RESOLVED_COUNT" "$EVAL_UNRESOLVED_COUNT" "$EVAL_ERROR_COUNT" "$ATTEMPTS_PATH" "$LATEST_PATH" "$RUN_LOG_PATH"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  exit 1
fi

if [[ "$EVAL_ERROR_COUNT" -gt 0 ]]; then
  exit 1
fi

if [[ "$INCOMPLETE_COUNT" -gt 0 ]]; then
  exit 20
fi

exit 0
