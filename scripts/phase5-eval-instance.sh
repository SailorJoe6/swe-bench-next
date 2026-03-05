#!/usr/bin/env bash
set -euo pipefail

DEFAULT_DATASET_NAME="SWE-bench/SWE-bench_Multilingual"
DEFAULT_NAMESPACE="${SWE_BENCH_EVAL_NAMESPACE:-none}"
DEFAULT_ARCH="arm64"
DEFAULT_MAX_WORKERS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CAMPAIGN_ROOT=""
INSTANCE_ID=""
PREDICTIONS_PATH=""
RUN_ID=""
DATASET_NAME="$DEFAULT_DATASET_NAME"
NAMESPACE="$DEFAULT_NAMESPACE"
ARCH="$DEFAULT_ARCH"
MAX_WORKERS="$DEFAULT_MAX_WORKERS"

usage() {
  cat <<USAGE
Usage: scripts/phase5-eval-instance.sh --campaign-root <path> --instance-id <id> [options]

Required:
  --campaign-root <path>    Campaign root for reports/state outputs
  --instance-id <id>        SWE-Bench instance id to evaluate

Options:
  --predictions-path <path> Override prediction artifact path
                            (default: <campaign-root>/instances/<instance-id>/<instance-id>.pred)
  --run-id <id>             Evaluation run id (default: phase5-eval-<instance-id>)
  --dataset-name <name>     Dataset name for run_evaluation
                            (default: ${DEFAULT_DATASET_NAME})
  --max-workers <n>         Harness max workers (default: ${DEFAULT_MAX_WORKERS})
  --namespace <name>        Eval namespace (default: ${DEFAULT_NAMESPACE})
  --arch <name>             Eval arch (default: ${DEFAULT_ARCH})
  -h, --help                Show this help message

Behavior:
  - Runs one instance through python -m swebench.harness.run_evaluation
  - Normalizes non-.json/.jsonl prediction artifacts to a temporary .jsonl path
  - Always passes --namespace and --arch explicitly
  - Writes harness log under reports/eval/<instance-id>/run_evaluation.log
  - Writes harness summary artifacts under <campaign-root>/evaluations
  - Writes machine-readable result under state/evals/<instance-id>.eval.json
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

resolve_python_bin() {
  if [[ -n "${SWE_BENCH_PYTHON_BIN:-}" ]]; then
    printf '%s' "$SWE_BENCH_PYTHON_BIN"
    return 0
  fi

  if [[ -x "$REPO_ROOT/venv/bin/python3" ]]; then
    printf '%s' "$REPO_ROOT/venv/bin/python3"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  return 1
}

write_eval_error_result() {
  local result_path="$1"
  local instance_id="$2"
  local run_id="$3"
  local predictions_path="$4"
  local report_dir="$5"
  local run_log="$6"
  local summary_path="$7"
  local started_at="$8"
  local finished_at="$9"
  local harness_exit_code="${10}"
  local detail="${11}"

  python3 - "$result_path" "$instance_id" "$run_id" "$predictions_path" "$report_dir" "$run_log" "$summary_path" "$started_at" "$finished_at" "$harness_exit_code" "$detail" <<'PY'
import json
import pathlib
import sys

(
    result_path_raw,
    instance_id,
    run_id,
    predictions_path,
    report_dir,
    run_log,
    summary_path,
    started_at,
    finished_at,
    harness_exit_code_raw,
    detail,
) = sys.argv[1:]

result_path = pathlib.Path(result_path_raw)
harness_exit_code = int(harness_exit_code_raw)

payload = {
    "instance_id": instance_id,
    "run_id": run_id,
    "attempt_started_at": started_at,
    "attempt_finished_at": finished_at,
    "predictions_path": predictions_path,
    "report_dir": report_dir,
    "run_log": run_log,
    "summary_path": summary_path,
    "evaluation_result": "eval_error",
    "harness_exit_code": harness_exit_code,
    "detail": detail,
}

result_path.parent.mkdir(parents=True, exist_ok=True)
result_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaign-root)
      [[ $# -ge 2 ]] || { error "--campaign-root requires a value"; exit 2; }
      CAMPAIGN_ROOT="$2"
      shift 2
      ;;
    --instance-id)
      [[ $# -ge 2 ]] || { error "--instance-id requires a value"; exit 2; }
      INSTANCE_ID="$2"
      shift 2
      ;;
    --predictions-path)
      [[ $# -ge 2 ]] || { error "--predictions-path requires a value"; exit 2; }
      PREDICTIONS_PATH="$2"
      shift 2
      ;;
    --run-id)
      [[ $# -ge 2 ]] || { error "--run-id requires a value"; exit 2; }
      RUN_ID="$2"
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

if [[ -z "$INSTANCE_ID" ]]; then
  error "--instance-id is required"
  usage >&2
  exit 2
fi

if ! is_positive_integer "$MAX_WORKERS"; then
  error "--max-workers must be a positive integer"
  exit 2
fi

CAMPAIGN_ROOT="$(absolute_path_from_pwd "$CAMPAIGN_ROOT")"

if [[ -z "$PREDICTIONS_PATH" ]]; then
  PREDICTIONS_PATH="$CAMPAIGN_ROOT/instances/$INSTANCE_ID/${INSTANCE_ID}.pred"
else
  PREDICTIONS_PATH="$(absolute_path_from_pwd "$PREDICTIONS_PATH")"
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="phase5-eval-${INSTANCE_ID}"
fi

if [[ ! -f "$PREDICTIONS_PATH" ]]; then
  error "Prediction artifact not found: $PREDICTIONS_PATH"
  exit 1
fi

if ! PYTHON_BIN="$(resolve_python_bin)"; then
  error "Unable to locate python3 runtime. Set SWE_BENCH_PYTHON_BIN."
  exit 1
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  error "Python runtime is not executable: $PYTHON_BIN"
  exit 1
fi

REPORT_DIR="$CAMPAIGN_ROOT/reports/eval/$INSTANCE_ID"
STATE_DIR="$CAMPAIGN_ROOT/state/evals"
EVALUATIONS_DIR="$CAMPAIGN_ROOT/evaluations"
RUN_LOG="$REPORT_DIR/run_evaluation.log"
RESULT_PATH="$STATE_DIR/${INSTANCE_ID}.eval.json"
EVAL_INPUT_PATH="$PREDICTIONS_PATH"

mkdir -p "$REPORT_DIR" "$STATE_DIR" "$EVALUATIONS_DIR"

if find "$EVALUATIONS_DIR" -maxdepth 1 -type f -name "*.${RUN_ID}.json" | read -r _; then
  error "Refusing to overwrite existing evaluation summary for run_id=$RUN_ID in $EVALUATIONS_DIR"
  exit 1
fi

if [[ "$PREDICTIONS_PATH" != *.json && "$PREDICTIONS_PATH" != *.jsonl ]]; then
  EVAL_INPUT_PATH="$REPORT_DIR/predictions.${RUN_ID}.jsonl"
  cp "$PREDICTIONS_PATH" "$EVAL_INPUT_PATH"
fi

attempt_started_at="$(timestamp_utc)"

set +e
(
  cd "$EVALUATIONS_DIR"
  "$PYTHON_BIN" -m swebench.harness.run_evaluation \
    --dataset_name "$DATASET_NAME" \
    --split test \
    --predictions_path "$EVAL_INPUT_PATH" \
    --max_workers "$MAX_WORKERS" \
    --run_id "$RUN_ID" \
    --arch "$ARCH" \
    --namespace "$NAMESPACE" \
    --report_dir "$REPORT_DIR"
) > "$RUN_LOG" 2>&1
harness_exit_code="$?"
set -e

attempt_finished_at="$(timestamp_utc)"

if [[ "$harness_exit_code" -ne 0 ]]; then
  write_eval_error_result \
    "$RESULT_PATH" \
    "$INSTANCE_ID" \
    "$RUN_ID" \
    "$PREDICTIONS_PATH" \
    "$REPORT_DIR" \
    "$RUN_LOG" \
    "" \
    "$attempt_started_at" \
    "$attempt_finished_at" \
    "$harness_exit_code" \
    "run_evaluation exited non-zero"

  error "run_evaluation failed for $INSTANCE_ID (exit=$harness_exit_code). See $RUN_LOG"
  exit "$harness_exit_code"
fi

SUMMARY_PATH="$(find "$EVALUATIONS_DIR" -maxdepth 1 -type f -name "*.${RUN_ID}.json" | LC_ALL=C sort | head -n 1)"
if [[ -z "$SUMMARY_PATH" ]]; then
  write_eval_error_result \
    "$RESULT_PATH" \
    "$INSTANCE_ID" \
    "$RUN_ID" \
    "$PREDICTIONS_PATH" \
    "$REPORT_DIR" \
    "$RUN_LOG" \
    "" \
    "$attempt_started_at" \
    "$attempt_finished_at" \
    "1" \
    "run_evaluation did not produce a summary JSON"
  error "Missing evaluation summary for run_id=$RUN_ID in $EVALUATIONS_DIR"
  exit 1
fi

set +e
mapfile -t parse_result < <(python3 - "$SUMMARY_PATH" "$INSTANCE_ID" "$RESULT_PATH" "$RUN_ID" "$PREDICTIONS_PATH" "$REPORT_DIR" "$RUN_LOG" "$attempt_started_at" "$attempt_finished_at" <<'PY'
import json
import pathlib
import sys

(
    summary_path_raw,
    instance_id,
    result_path_raw,
    run_id,
    predictions_path,
    report_dir,
    run_log,
    started_at,
    finished_at,
) = sys.argv[1:]

summary_path = pathlib.Path(summary_path_raw)
result_path = pathlib.Path(result_path_raw)
payload = json.loads(summary_path.read_text(encoding="utf-8"))

def as_id_set(key):
    value = payload.get(key)
    if not isinstance(value, list):
        return set()
    return {item for item in value if isinstance(item, str)}

resolved_ids = as_id_set("resolved_ids")
unresolved_ids = as_id_set("unresolved_ids")
error_ids = as_id_set("error_ids")

evaluation_result = "eval_error"
detail = "instance missing from resolved/unresolved/error lists"
if instance_id in resolved_ids:
    evaluation_result = "resolved"
    detail = "instance found in resolved_ids"
elif instance_id in unresolved_ids:
    evaluation_result = "unresolved"
    detail = "instance found in unresolved_ids"
elif instance_id in error_ids:
    evaluation_result = "eval_error"
    detail = "instance found in error_ids"

result_payload = {
    "instance_id": instance_id,
    "run_id": run_id,
    "attempt_started_at": started_at,
    "attempt_finished_at": finished_at,
    "predictions_path": predictions_path,
    "report_dir": report_dir,
    "run_log": run_log,
    "summary_path": str(summary_path),
    "evaluation_result": evaluation_result,
    "harness_exit_code": 0,
    "detail": detail,
    "summary": {
        "total_instances": payload.get("total_instances"),
        "submitted_instances": payload.get("submitted_instances"),
        "completed_instances": payload.get("completed_instances"),
        "resolved_instances": payload.get("resolved_instances"),
        "unresolved_instances": payload.get("unresolved_instances"),
        "error_instances": payload.get("error_instances"),
    },
}

result_path.parent.mkdir(parents=True, exist_ok=True)
result_path.write_text(json.dumps(result_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

print(evaluation_result)
print(detail)
print(str(summary_path))
PY
)
parse_exit_code="$?"
set -e

if [[ "$parse_exit_code" -ne 0 ]]; then
  write_eval_error_result \
    "$RESULT_PATH" \
    "$INSTANCE_ID" \
    "$RUN_ID" \
    "$PREDICTIONS_PATH" \
    "$REPORT_DIR" \
    "$RUN_LOG" \
    "$SUMMARY_PATH" \
    "$attempt_started_at" \
    "$attempt_finished_at" \
    "1" \
    "failed to parse evaluation summary"
  error "Failed to parse evaluation summary: $SUMMARY_PATH"
  exit 1
fi

EVAL_RESULT="${parse_result[0]:-eval_error}"
DETAIL="${parse_result[1]:-}"
SUMMARY_PATH="${parse_result[2]:-$SUMMARY_PATH}"

echo "instance_id=$INSTANCE_ID evaluation_result=$EVAL_RESULT run_id=$RUN_ID summary_path=$SUMMARY_PATH result_path=$RESULT_PATH"
if [[ "$EVAL_RESULT" == "eval_error" && "$DETAIL" != "" ]]; then
  echo "detail=$DETAIL"
fi

exit 0
