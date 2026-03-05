#!/usr/bin/env bash
set -euo pipefail

DEFAULT_DATASET_NAME="SWE-bench/SWE-bench_Multilingual"
DEFAULT_NAMESPACE="${SWE_BENCH_EVAL_NAMESPACE:-none}"
DEFAULT_ARCH="arm64"
DEFAULT_MAX_WORKERS=1
DEFAULT_RUN_ID_PREFIX="phase5-eval"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_SCRIPT="$SCRIPT_DIR/phase5-eval-instance.sh"

CAMPAIGN_ROOT=""
TARGETS_FILE=""
DATASET_NAME="$DEFAULT_DATASET_NAME"
NAMESPACE="$DEFAULT_NAMESPACE"
ARCH="$DEFAULT_ARCH"
MAX_WORKERS="$DEFAULT_MAX_WORKERS"
RUN_ID_PREFIX="$DEFAULT_RUN_ID_PREFIX"
RETRY_ALL=0

usage() {
  cat <<USAGE
Usage: scripts/phase5-run-evals-sequential.sh --campaign-root <path> [options]

Required:
  --campaign-root <path>  Campaign run root containing targets/state/reports

Options:
  --targets-file <path>   Target instance list (default: <campaign-root>/targets/unresolved_ids.txt)
  --dataset-name <name>   Dataset name for run_evaluation (default: ${DEFAULT_DATASET_NAME})
  --max-workers <n>       Harness max workers (default: ${DEFAULT_MAX_WORKERS})
  --namespace <name>      Eval namespace (default: ${DEFAULT_NAMESPACE})
  --arch <name>           Eval arch (default: ${DEFAULT_ARCH})
  --run-id-prefix <str>   Prefix for eval run_id (default: ${DEFAULT_RUN_ID_PREFIX})
  --retry-all             Re-run evaluations even if latest attempt is already terminal
  -h, --help              Show this help message

Behavior:
  - Processes campaign targets one instance at a time in foreground (blocking per instance)
  - Reads latest prediction attempt from state/attempts.jsonl + state/instance_latest.json
  - Evaluates only attempts with prediction.patch_non_empty=true
  - Updates evaluation/classification fields in attempts.jsonl and instance_latest.json
  - Continues through per-instance evaluation failures and records eval_error outcomes
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

resolve_latest_attempt() {
  local attempts_path="$1"
  local latest_path="$2"
  local campaign_root="$3"
  local instance_id="$4"
  python3 - "$attempts_path" "$latest_path" "$campaign_root" "$instance_id" <<'PY'
import json
import pathlib
import sys

attempts_path = pathlib.Path(sys.argv[1])
latest_path = pathlib.Path(sys.argv[2])
campaign_root = pathlib.Path(sys.argv[3])
instance_id = sys.argv[4]

rows = []
for raw_line in attempts_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(row, dict) and row.get("instance_id") == instance_id:
        rows.append(row)

if not rows:
    print("")
    print("")
    print("false")
    print("not_run")
    print("")
    raise SystemExit(0)

preferred_attempt_id = None
if latest_path.exists():
    try:
        latest_payload = json.loads(latest_path.read_text(encoding="utf-8"))
    except Exception:
        latest_payload = {}
    if isinstance(latest_payload, dict):
        latest_entry = latest_payload.get(instance_id)
        if isinstance(latest_entry, dict):
            value = latest_entry.get("attempt_id")
            if isinstance(value, str) and value:
                preferred_attempt_id = value

selected = None
if preferred_attempt_id:
    for row in rows:
        if row.get("attempt_id") == preferred_attempt_id:
            selected = row
            break
if selected is None:
    selected = rows[-1]

attempt_id = selected.get("attempt_id")
if not isinstance(attempt_id, str):
    attempt_id = ""

prediction = selected.get("prediction")
if not isinstance(prediction, dict):
    prediction = {}

pred_path = prediction.get("pred_path")
if not isinstance(pred_path, str) or not pred_path:
    pred_path = str(campaign_root / "instances" / instance_id / f"{instance_id}.pred")

patch_non_empty = prediction.get("patch_non_empty")
if not isinstance(patch_non_empty, bool):
    patch_non_empty = False

evaluation = selected.get("evaluation")
if not isinstance(evaluation, dict):
    evaluation = {}
evaluation_result = evaluation.get("result")
if not isinstance(evaluation_result, str) or not evaluation_result:
    evaluation_result = "not_run"

prediction_status = prediction.get("status")
if not isinstance(prediction_status, str):
    prediction_status = ""

print(attempt_id)
print(pred_path)
print("true" if patch_non_empty else "false")
print(evaluation_result)
print(prediction_status)
PY
}

read_eval_result() {
  local result_path="$1"
  python3 - "$result_path" <<'PY'
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
if not result_path.exists():
    print("eval_error")
    print("missing evaluation result artifact")
    raise SystemExit(0)

try:
    payload = json.loads(result_path.read_text(encoding="utf-8"))
except Exception:
    print("eval_error")
    print("failed to parse evaluation result artifact")
    raise SystemExit(0)

result = payload.get("evaluation_result")
if result not in {"resolved", "unresolved", "eval_error"}:
    result = "eval_error"

detail = payload.get("detail")
if not isinstance(detail, str):
    detail = ""

print(result)
print(detail)
PY
}

update_attempt_history() {
  local attempts_path="$1"
  local latest_path="$2"
  local instance_id="$3"
  local attempt_id="$4"
  local evaluation_result="$5"
  local classification="$6"
  local result_path="$7"
  local eval_exit_code="$8"
  local finished_at="$9"
  local detail="${10}"

  python3 - "$attempts_path" "$latest_path" "$instance_id" "$attempt_id" "$evaluation_result" "$classification" "$result_path" "$eval_exit_code" "$finished_at" "$detail" <<'PY'
import json
import pathlib
import sys

(
    attempts_path_raw,
    latest_path_raw,
    instance_id,
    attempt_id,
    evaluation_result,
    classification,
    result_path,
    eval_exit_code_raw,
    finished_at,
    detail,
) = sys.argv[1:]

attempts_path = pathlib.Path(attempts_path_raw)
latest_path = pathlib.Path(latest_path_raw)
eval_exit_code = int(eval_exit_code_raw)

lines = attempts_path.read_text(encoding="utf-8").splitlines()
updated = []
matched_row = None

for raw_line in lines:
    line = raw_line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        updated.append(raw_line)
        continue

    if (
        isinstance(row, dict)
        and row.get("instance_id") == instance_id
        and row.get("attempt_id") == attempt_id
    ):
        evaluation = row.get("evaluation")
        if not isinstance(evaluation, dict):
            evaluation = {}
        evaluation["executed"] = True
        evaluation["result"] = evaluation_result
        evaluation["result_path"] = result_path
        evaluation["updated_at"] = finished_at
        evaluation["exit_code"] = eval_exit_code
        if detail:
            evaluation["detail"] = detail
        row["evaluation"] = evaluation
        row["classification"] = classification

        note_tail = f"evaluation result={evaluation_result} exit_code={eval_exit_code}"
        if detail:
            note_tail += f" detail={detail}"
        notes = row.get("notes")
        if isinstance(notes, str) and notes.strip():
            row["notes"] = notes + "; " + note_tail
        else:
            row["notes"] = note_tail

        matched_row = row
        updated.append(json.dumps(row, separators=(",", ":")))
    else:
        updated.append(json.dumps(row, separators=(",", ":")))

attempts_path.write_text("\n".join(updated) + "\n", encoding="utf-8")

if latest_path.exists():
    try:
        latest_payload = json.loads(latest_path.read_text(encoding="utf-8"))
    except Exception:
        latest_payload = {}
else:
    latest_payload = {}

if not isinstance(latest_payload, dict):
    latest_payload = {}

entry = latest_payload.get(instance_id)
if not isinstance(entry, dict):
    entry = {"instance_id": instance_id}

entry["attempt_id"] = attempt_id
entry["evaluation_result"] = evaluation_result
entry["classification"] = classification
entry["evaluation_updated_at"] = finished_at

if isinstance(matched_row, dict):
    prediction = matched_row.get("prediction")
    if isinstance(prediction, dict):
        prediction_status = prediction.get("status")
        if isinstance(prediction_status, str):
            entry["prediction_status"] = prediction_status
        patch_non_empty = prediction.get("patch_non_empty")
        if isinstance(patch_non_empty, bool):
            entry["patch_non_empty"] = patch_non_empty

latest_payload[instance_id] = entry
latest_path.write_text(json.dumps(latest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
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
    --dataset-name)
      [[ $# -ge 2 ]] || { error "--dataset-name requires a value"; exit 2; }
      DATASET_NAME="$2"
      shift 2
      ;;
    --max-workers)
      [[ $# -ge 2 ]] || { error "--max-workers requires a value"; exit 2; }
      MAX_WORKERS="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || { error "--namespace requires a value"; exit 2; }
      NAMESPACE="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || { error "--arch requires a value"; exit 2; }
      ARCH="$2"
      shift 2
      ;;
    --run-id-prefix)
      [[ $# -ge 2 ]] || { error "--run-id-prefix requires a value"; exit 2; }
      RUN_ID_PREFIX="$2"
      shift 2
      ;;
    --retry-all)
      RETRY_ALL=1
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
  error "--campaign-root is required"
  usage >&2
  exit 2
fi

if ! is_positive_integer "$MAX_WORKERS"; then
  error "--max-workers must be a positive integer"
  exit 2
fi

if [[ ! -x "$EVAL_SCRIPT" ]]; then
  error "eval wrapper not found or not executable: $EVAL_SCRIPT"
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
ATTEMPTS_PATH="$STATE_DIR/attempts.jsonl"
LATEST_PATH="$STATE_DIR/instance_latest.json"
RUN_LOG_PATH="$REPORT_DIR/run_evals_sequential.log"

if [[ ! -f "$ATTEMPTS_PATH" ]]; then
  error "attempt history not found: $ATTEMPTS_PATH"
  exit 1
fi

mkdir -p "$STATE_DIR" "$REPORT_DIR"
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

EVALUATED_COUNT=0
SKIPPED_COUNT=0
RESOLVED_COUNT=0
UNRESOLVED_COUNT=0
EVAL_ERROR_COUNT=0

for instance_id in "${INSTANCE_IDS[@]}"; do
  mapfile -t latest_fields < <(resolve_latest_attempt "$ATTEMPTS_PATH" "$LATEST_PATH" "$CAMPAIGN_ROOT" "$instance_id")
  latest_attempt_id="${latest_fields[0]:-}"
  pred_path="${latest_fields[1]:-}"
  patch_non_empty="${latest_fields[2]:-false}"
  prior_eval_result="${latest_fields[3]:-not_run}"

  if [[ -z "$latest_attempt_id" ]]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    printf '[%s] skip instance=%s reason=no_prediction_attempt\n' "$(timestamp_utc)" "$instance_id" >> "$RUN_LOG_PATH"
    continue
  fi

  if [[ "$patch_non_empty" != "true" ]]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    printf '[%s] skip instance=%s attempt=%s reason=patch_empty_or_missing\n' \
      "$(timestamp_utc)" "$instance_id" "$latest_attempt_id" >> "$RUN_LOG_PATH"
    continue
  fi

  if [[ "$RETRY_ALL" -ne 1 && "$prior_eval_result" != "not_run" ]]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    printf '[%s] skip instance=%s attempt=%s reason=evaluation_already_terminal eval_result=%s\n' \
      "$(timestamp_utc)" "$instance_id" "$latest_attempt_id" "$prior_eval_result" >> "$RUN_LOG_PATH"
    continue
  fi

  run_id="${RUN_ID_PREFIX}-${latest_attempt_id}"
  EVALUATED_COUNT=$((EVALUATED_COUNT + 1))

  set +e
  "$EVAL_SCRIPT" \
    --campaign-root "$CAMPAIGN_ROOT" \
    --instance-id "$instance_id" \
    --predictions-path "$pred_path" \
    --run-id "$run_id" \
    --dataset-name "$DATASET_NAME" \
    --max-workers "$MAX_WORKERS" \
    --namespace "$NAMESPACE" \
    --arch "$ARCH" >> "$RUN_LOG_PATH" 2>&1
  eval_exit_code="$?"
  set -e

  eval_result_path="$STATE_DIR/evals/${instance_id}.eval.json"
  mapfile -t eval_fields < <(read_eval_result "$eval_result_path")
  evaluation_result="${eval_fields[0]:-eval_error}"
  detail="${eval_fields[1]:-}"

  if [[ "$eval_exit_code" -ne 0 ]]; then
    evaluation_result="eval_error"
    if [[ -n "$detail" ]]; then
      detail="$detail; eval wrapper exit_code=$eval_exit_code"
    else
      detail="eval wrapper exit_code=$eval_exit_code"
    fi
  fi

  case "$evaluation_result" in
    resolved)
      classification="resolved"
      RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
      ;;
    unresolved)
      classification="agent_failure"
      UNRESOLVED_COUNT=$((UNRESOLVED_COUNT + 1))
      ;;
    *)
      evaluation_result="eval_error"
      classification="infra_unclassified"
      EVAL_ERROR_COUNT=$((EVAL_ERROR_COUNT + 1))
      ;;
  esac

  eval_finished_at="$(timestamp_utc)"
  update_attempt_history \
    "$ATTEMPTS_PATH" \
    "$LATEST_PATH" \
    "$instance_id" \
    "$latest_attempt_id" \
    "$evaluation_result" \
    "$classification" \
    "$eval_result_path" \
    "$eval_exit_code" \
    "$eval_finished_at" \
    "$detail"

  printf '[%s] instance=%s attempt=%s eval_result=%s classification=%s exit_code=%s\n' \
    "$(timestamp_utc)" "$instance_id" "$latest_attempt_id" "$evaluation_result" "$classification" "$eval_exit_code" >> "$RUN_LOG_PATH"
done

printf 'campaign_root=%s targets_file=%s total=%s evaluated=%s skipped=%s resolved=%s unresolved=%s eval_error=%s attempts_file=%s latest_file=%s run_log=%s\n' \
  "$CAMPAIGN_ROOT" "$TARGETS_FILE" "${#INSTANCE_IDS[@]}" "$EVALUATED_COUNT" "$SKIPPED_COUNT" \
  "$RESOLVED_COUNT" "$UNRESOLVED_COUNT" "$EVAL_ERROR_COUNT" "$ATTEMPTS_PATH" "$LATEST_PATH" "$RUN_LOG_PATH"

if [[ "$EVAL_ERROR_COUNT" -gt 0 ]]; then
  exit 1
fi

exit 0
