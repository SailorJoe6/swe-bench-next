#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="SWE-bench/SWE-bench_Multilingual"
DATASET_SUBSET="multilingual"
DATASET_SPLIT="test"
MODEL_NAME_OR_PATH="qwen3-coder-next-FP8,codex,ralph"
INSTANCE_FIXTURE_ENV_VAR="SWE_BENCH_INSTANCES_FILE"
MAX_LOOPS_DEFAULT=50

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
START_SCRIPT="$SCRIPT_DIR/start-swebench.sh"
RUN_ROOT_PARENT="$REPO_ROOT/results/phase5/ralph-codex-local"

INSTANCE_FILE=""
MAX_LOOPS="$MAX_LOOPS_DEFAULT"

usage() {
  cat <<USAGE
Usage: scripts/run-swebench-batch.sh [options]

Options:
  --instance-file <path>  Optional subset input. Supports newline-delimited IDs,
                          JSON array/object, or JSONL records with instance_id.
  --max-loops <n>         Execute-loop pass budget per instance (default: ${MAX_LOOPS_DEFAULT})
  -h, --help              Show this help message

Behavior:
  - Resolves SWE-Bench Multilingual test instance scope
  - Sorts instance IDs lexicographically
  - Creates run root: results/phase5/ralph-codex-local/<timestamp>
  - Invokes start-swebench.sh per instance with:
      --output-dir <run_root>/<instance_id>
      --manifest-dir <run_root>
  - Continues after per-instance failures
  - Builds <run_root>/predictions.jsonl from per-instance .pred files
USAGE
}

error() {
  echo "Error: $*" >&2
}

timestamp_run_root() {
  date -u +"%Y%m%dT%H%M%SZ"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

collect_instance_ids() {
  local instance_file="$1"

  python3 - "$instance_file" "$DATASET_NAME" "$DATASET_SUBSET" "$DATASET_SPLIT" "$INSTANCE_FIXTURE_ENV_VAR" <<'PY'
import json
import os
import pathlib
import sys

instance_file, dataset_name, dataset_subset, dataset_split, fixture_env_var = sys.argv[1:]
fixture_path = os.environ.get(fixture_env_var, "").strip()


def normalize_ids(values):
    ids = []
    for value in values:
        if not isinstance(value, str):
            continue
        trimmed = value.strip()
        if trimmed:
            ids.append(trimmed)
    return sorted(set(ids))


def records_to_ids(records, source_name):
    ids = []
    for record in records:
        if isinstance(record, str):
            ids.append(record)
            continue
        if isinstance(record, dict):
            instance_id = record.get("instance_id")
            if isinstance(instance_id, str) and instance_id.strip():
                ids.append(instance_id)
                continue
            raise RuntimeError(f"record in {source_name} is missing non-empty instance_id")
        raise RuntimeError(f"unsupported record type in {source_name}: {type(record).__name__}")
    return normalize_ids(ids)


def parse_json_or_jsonl(path):
    text = path.read_text(encoding="utf-8")
    suffix = path.suffix.lower()

    if suffix == ".jsonl":
        rows = []
        for line_number, line in enumerate(text.splitlines(), start=1):
            row = line.strip()
            if not row:
                continue
            try:
                rows.append(json.loads(row))
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"invalid JSONL in {path} at line {line_number}: {exc.msg}") from exc
        return rows

    if suffix == ".json":
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid JSON in {path}: {exc.msg}") from exc

        if isinstance(data, list):
            return data
        if isinstance(data, dict):
            if isinstance(data.get("instances"), list):
                return data["instances"]
            return [data]
        raise RuntimeError(f"unsupported JSON structure in {path}; expected object or array")

    return None


def parse_instance_file(path_string):
    path = pathlib.Path(path_string)
    if not path.exists():
        raise RuntimeError(f"--instance-file path does not exist: {path}")

    parsed = parse_json_or_jsonl(path)
    if parsed is not None:
        return records_to_ids(parsed, str(path))

    lines = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        lines.append(stripped)
    return normalize_ids(lines)


def parse_default_scope():
    if fixture_path:
        fixture = pathlib.Path(fixture_path)
        if not fixture.exists():
            raise RuntimeError(f"{fixture_env_var} path does not exist: {fixture}")
        parsed = parse_json_or_jsonl(fixture)
        if parsed is None:
            raise RuntimeError(
                f"{fixture_env_var} must point to .json or .jsonl when used as default scope fixture"
            )
        return records_to_ids(parsed, str(fixture))

    try:
        from datasets import load_dataset
    except Exception as exc:  # pragma: no cover - dependency/runtime environment branch
        raise RuntimeError(
            "python package 'datasets' is required to resolve batch default scope; "
            f"install it or set {fixture_env_var}"
        ) from exc

    dataset = load_dataset(dataset_name, dataset_subset, split=dataset_split)
    ids = []
    for record in dataset:
        if isinstance(record, dict):
            instance_id = record.get("instance_id")
            if isinstance(instance_id, str) and instance_id.strip():
                ids.append(instance_id)
    return normalize_ids(ids)


if instance_file:
    instance_ids = parse_instance_file(instance_file)
else:
    instance_ids = parse_default_scope()

if not instance_ids:
    source = instance_file if instance_file else f"{dataset_name} [{dataset_subset}/{dataset_split}]"
    raise RuntimeError(f"no instance IDs resolved from source: {source}")

for instance_id in instance_ids:
    print(instance_id)
PY
}

read_status_value() {
  local status_path="$1"
  python3 - "$status_path" <<'PY'
import json
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
if not status_path.exists():
    print("")
    raise SystemExit(0)

try:
    payload = json.loads(status_path.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)

status = payload.get("status", "")
print(status if isinstance(status, str) else "")
PY
}

build_predictions_jsonl() {
  local predictions_path="$1"
  local run_root="$2"
  shift 2

  python3 - "$predictions_path" "$MODEL_NAME_OR_PATH" "$run_root" "$@" <<'PY'
import json
import pathlib
import sys

predictions_path = pathlib.Path(sys.argv[1])
model_name_or_path = sys.argv[2]
run_root = pathlib.Path(sys.argv[3])
instance_ids = sys.argv[4:]

rows = []
for instance_id in instance_ids:
    pred_path = run_root / instance_id / f"{instance_id}.pred"
    payload = None

    if pred_path.exists():
        text = pred_path.read_text(encoding="utf-8").strip()
        if text:
            try:
                parsed = json.loads(text)
                if isinstance(parsed, dict):
                    payload = parsed
            except json.JSONDecodeError:
                payload = None

    if payload is None:
        payload = {
            "model_name_or_path": model_name_or_path,
            "instance_id": instance_id,
            "model_patch": "",
        }
    else:
        payload["model_name_or_path"] = model_name_or_path
        payload["instance_id"] = instance_id
        model_patch = payload.get("model_patch", "")
        payload["model_patch"] = model_patch if isinstance(model_patch, str) else ""

    rows.append(json.dumps(payload, separators=(",", ":")))

predictions_path.parent.mkdir(parents=True, exist_ok=True)
predictions_path.write_text(("\n".join(rows) + "\n") if rows else "", encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-file)
      [[ $# -ge 2 ]] || { error "--instance-file requires a value"; exit 2; }
      INSTANCE_FILE="$2"
      shift 2
      ;;
    --max-loops)
      [[ $# -ge 2 ]] || { error "--max-loops requires a value"; exit 2; }
      MAX_LOOPS="$2"
      shift 2
      ;;
    --profile|--codex-profile|--interactive|--claude)
      error "Unsupported option '$1'. This runner delegates to start-swebench.sh with hardcoded Codex local profile."
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

if ! is_positive_integer "$MAX_LOOPS"; then
  error "--max-loops must be a positive integer"
  exit 2
fi

if [[ ! -x "$START_SCRIPT" ]]; then
  error "start runner not found or not executable: $START_SCRIPT"
  exit 1
fi

if [[ -n "$INSTANCE_FILE" && ! -f "$INSTANCE_FILE" ]]; then
  error "--instance-file does not exist: $INSTANCE_FILE"
  exit 1
fi

if ! mapfile -t INSTANCE_IDS < <(collect_instance_ids "$INSTANCE_FILE"); then
  error "Failed to resolve instance IDs for batch scope"
  exit 1
fi

if [[ ${#INSTANCE_IDS[@]} -eq 0 ]]; then
  error "No instance IDs resolved for batch scope"
  exit 1
fi

RUN_ROOT="$RUN_ROOT_PARENT/$(timestamp_run_root)"
mkdir -p "$RUN_ROOT"

INSTANCE_ORDER_PATH="$RUN_ROOT/instance_order.txt"
BATCH_LOG_PATH="$RUN_ROOT/run_swebench_batch.log"
PREDICTIONS_PATH="$RUN_ROOT/predictions.jsonl"

: > "$INSTANCE_ORDER_PATH"
: > "$BATCH_LOG_PATH"

SUCCESS_COUNT=0
FAILED_COUNT=0
INCOMPLETE_COUNT=0

for instance_id in "${INSTANCE_IDS[@]}"; do
  instance_output_dir="$RUN_ROOT/$instance_id"
  echo "$instance_id" >> "$INSTANCE_ORDER_PATH"

  set +e
  "$START_SCRIPT" \
    --instance-id "$instance_id" \
    --output-dir "$instance_output_dir" \
    --manifest-dir "$RUN_ROOT" \
    --max-loops "$MAX_LOOPS" >>"$BATCH_LOG_PATH" 2>&1
  invocation_exit="$?"
  set -e

  status_path="$instance_output_dir/${instance_id}.status.json"
  status_value="$(read_status_value "$status_path")"

  case "$status_value" in
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
      # Keep batch execution resilient even if start runner had an unexpected failure
      # and did not emit a status file.
      FAILED_COUNT=$((FAILED_COUNT + 1))
      printf 'warning: instance %s missing/invalid status file (exit=%s)\n' \
        "$instance_id" "$invocation_exit" >> "$BATCH_LOG_PATH"
      ;;
  esac
done

build_predictions_jsonl "$PREDICTIONS_PATH" "$RUN_ROOT" "${INSTANCE_IDS[@]}"

printf 'run_root=%s total=%s success=%s failed=%s incomplete=%s\n' \
  "$RUN_ROOT" "${#INSTANCE_IDS[@]}" "$SUCCESS_COUNT" "$FAILED_COUNT" "$INCOMPLETE_COUNT"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  exit 1
fi

if [[ "$INCOMPLETE_COUNT" -gt 0 ]]; then
  exit 20
fi

exit 0
