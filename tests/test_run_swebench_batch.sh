#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BATCH_SCRIPT="$REPO_ROOT/scripts/run-swebench-batch.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$context (expected '$expected', got '$actual')"
  fi
}

make_isolated_batch_root() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/scripts"
  cp "$BATCH_SCRIPT" "$tmpdir/scripts/run-swebench-batch.sh"
  chmod +x "$tmpdir/scripts/run-swebench-batch.sh"

  cat > "$tmpdir/scripts/start-swebench.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME_OR_PATH="qwen3-coder-next-FP8,codex,ralph"
INSTANCE_ID=""
OUTPUT_DIR=""
MANIFEST_DIR=""
MAX_LOOPS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id)
      INSTANCE_ID="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --manifest-dir)
      MANIFEST_DIR="$2"
      shift 2
      ;;
    --max-loops)
      MAX_LOOPS="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$INSTANCE_ID" ]] || { echo "missing --instance-id" >&2; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || { echo "missing --output-dir" >&2; exit 2; }
[[ -n "$MANIFEST_DIR" ]] || { echo "missing --manifest-dir" >&2; exit 2; }

if [[ -z "${FAKE_START_INVOCATIONS_FILE:-}" ]]; then
  echo "FAKE_START_INVOCATIONS_FILE is required" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR" "$MANIFEST_DIR"
printf '%s|%s|%s|%s\n' "$INSTANCE_ID" "$OUTPUT_DIR" "$MANIFEST_DIR" "$MAX_LOOPS" >> "$FAKE_START_INVOCATIONS_FILE"

instance_in_csv() {
  local target="$1"
  local csv="${2:-}"
  local item=""
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    if [[ "$item" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

STATUS="success"
FAILURE_REASON_CODE="null"
FAILURE_REASON_DETAIL=""
ERROR_LOG=""
MODEL_PATCH="diff-for-${INSTANCE_ID}"
EXIT_CODE=0

if instance_in_csv "$INSTANCE_ID" "${FAKE_START_FAIL_IDS:-}"; then
  STATUS="failed"
  FAILURE_REASON_CODE="runtime_error"
  FAILURE_REASON_DETAIL="forced failure for ${INSTANCE_ID}"
  MODEL_PATCH=""
  EXIT_CODE=1
elif instance_in_csv "$INSTANCE_ID" "${FAKE_START_INCOMPLETE_IDS:-}"; then
  STATUS="incomplete"
  FAILURE_REASON_CODE="incomplete"
  FAILURE_REASON_DETAIL="forced incomplete for ${INSTANCE_ID}"
  MODEL_PATCH=""
  EXIT_CODE=20
fi

python3 - "$OUTPUT_DIR/${INSTANCE_ID}.pred" "$MODEL_NAME_OR_PATH" "$INSTANCE_ID" "$MODEL_PATCH" <<'PY'
import json
import pathlib
import sys

path, model_name_or_path, instance_id, model_patch = sys.argv[1:]
payload = {
    "model_name_or_path": model_name_or_path,
    "instance_id": instance_id,
    "model_patch": model_patch,
}
pathlib.Path(path).write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
PY

python3 - "$OUTPUT_DIR/${INSTANCE_ID}.status.json" "$INSTANCE_ID" "$STATUS" "$FAILURE_REASON_CODE" "$FAILURE_REASON_DETAIL" "$ERROR_LOG" <<'PY'
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
pathlib.Path(status_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

python3 - "$MANIFEST_DIR/run_manifest.json" "$INSTANCE_ID" "$STATUS" "$FAILURE_REASON_CODE" <<'PY'
import json
import pathlib
import sys

manifest_path, instance_id, status, failure_reason_code = sys.argv[1:]
path = pathlib.Path(manifest_path)
if path.exists():
    payload = json.loads(path.read_text(encoding="utf-8"))
else:
    payload = {"instances": {}}
payload["instances"][instance_id] = {
    "instance_id": instance_id,
    "status": status,
    "failure_reason_code": None if failure_reason_code == "null" else failure_reason_code,
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

if [[ -n "$MODEL_PATCH" ]]; then
  printf '%s\n' "$MODEL_PATCH" > "$OUTPUT_DIR/${INSTANCE_ID}.patch"
else
  : > "$OUTPUT_DIR/${INSTANCE_ID}.patch"
fi

exit "$EXIT_CODE"
EOF
  chmod +x "$tmpdir/scripts/start-swebench.sh"
  echo "$tmpdir"
}

write_instance_file() {
  local path="$1"
  cat > "$path" <<'EOF'
repo__zeta-3
repo__alpha-1
repo__beta-2
repo__alpha-1
EOF
}

run_case_ordering_and_aggregation() {
  local tmpdir
  local instance_file
  local invocations_file
  local run_root
  tmpdir="$(make_isolated_batch_root)"
  instance_file="$tmpdir/instances.txt"
  invocations_file="$tmpdir/invocations.log"
  write_instance_file "$instance_file"

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" ./scripts/run-swebench-batch.sh --instance-file "$instance_file" --max-loops 7
  ) > /tmp/run-swebench-batch-test.out 2> /tmp/run-swebench-batch-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "all-success batch run should exit 0"

  run_root="$(find "$tmpdir/results/phase5/ralph-codex-local" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$run_root" ]] || fail "run root directory not created"

  [[ -f "$run_root/run_manifest.json" ]] || fail "manifest should be created by delegated start script"
  [[ -f "$run_root/predictions.jsonl" ]] || fail "predictions.jsonl should be created"
  [[ -f "$run_root/instance_order.txt" ]] || fail "instance_order.txt should be created"

  python3 - "$invocations_file" "$run_root" "$run_root/predictions.jsonl" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
run_root = pathlib.Path(sys.argv[2])
predictions_path = pathlib.Path(sys.argv[3])

expected_ids = ["repo__alpha-1", "repo__beta-2", "repo__zeta-3"]
invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 3, invocations

seen_ids = []
for row in invocations:
    instance_id, output_dir, manifest_dir, max_loops = row.split("|")
    seen_ids.append(instance_id)
    assert pathlib.Path(output_dir) == run_root / instance_id
    assert pathlib.Path(manifest_dir) == run_root
    assert max_loops == "7"

assert seen_ids == expected_ids, seen_ids

prediction_lines = [line for line in predictions_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(prediction_lines) == 3, prediction_lines

prediction_ids = []
for line in prediction_lines:
    payload = json.loads(line)
    prediction_ids.append(payload["instance_id"])
    assert payload["model_name_or_path"] == "qwen3-coder-next-FP8,codex,ralph"
    assert payload["model_patch"] == f"diff-for-{payload['instance_id']}"

assert prediction_ids == expected_ids, prediction_ids
PY
}

run_case_continue_on_failure() {
  local tmpdir
  local instance_file
  local invocations_file
  local run_root
  tmpdir="$(make_isolated_batch_root)"
  instance_file="$tmpdir/instances.txt"
  invocations_file="$tmpdir/invocations.log"
  write_instance_file "$instance_file"

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" FAKE_START_FAIL_IDS="repo__beta-2" ./scripts/run-swebench-batch.sh --instance-file "$instance_file"
  ) > /tmp/run-swebench-batch-test.out 2> /tmp/run-swebench-batch-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "batch should exit 1 when any instance fails"

  run_root="$(find "$tmpdir/results/phase5/ralph-codex-local" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$run_root" ]] || fail "run root directory not created for failure case"

  python3 - "$invocations_file" "$run_root/predictions.jsonl" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
predictions_path = pathlib.Path(sys.argv[2])

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 3, invocations
assert [line.split("|")[0] for line in invocations] == ["repo__alpha-1", "repo__beta-2", "repo__zeta-3"]

predictions = [json.loads(line) for line in predictions_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(predictions) == 3, predictions

by_id = {item["instance_id"]: item for item in predictions}
assert by_id["repo__beta-2"]["model_patch"] == ""
assert by_id["repo__alpha-1"]["model_patch"] == "diff-for-repo__alpha-1"
assert by_id["repo__zeta-3"]["model_patch"] == "diff-for-repo__zeta-3"
PY
}

run_case_default_scope_fixture_without_instance_file() {
  local tmpdir
  local fixture_file
  local invocations_file
  local run_root
  tmpdir="$(make_isolated_batch_root)"
  fixture_file="$tmpdir/instances.jsonl"
  invocations_file="$tmpdir/invocations.log"

  cat > "$fixture_file" <<'EOF'
{"instance_id":"repo__kilo-9","problem_statement":"x"}
{"instance_id":"repo__echo-4","problem_statement":"y"}
{"instance_id":"repo__echo-4","problem_statement":"z"}
EOF

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" SWE_BENCH_INSTANCES_FILE="$fixture_file" ./scripts/run-swebench-batch.sh
  ) > /tmp/run-swebench-batch-test.out 2> /tmp/run-swebench-batch-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "batch default-scope run should succeed with fixture override"

  run_root="$(find "$tmpdir/results/phase5/ralph-codex-local" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$run_root" ]] || fail "run root directory not created for default-scope case"

  python3 - "$invocations_file" "$run_root/predictions.jsonl" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
predictions_path = pathlib.Path(sys.argv[2])

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
ids = [line.split("|")[0] for line in invocations]
assert ids == ["repo__echo-4", "repo__kilo-9"], ids

predictions = [json.loads(line) for line in predictions_path.read_text(encoding="utf-8").splitlines() if line.strip()]
prediction_ids = [payload["instance_id"] for payload in predictions]
assert prediction_ids == ["repo__echo-4", "repo__kilo-9"], prediction_ids
PY
}

run_case_ordering_and_aggregation
run_case_continue_on_failure
run_case_default_scope_fixture_without_instance_file

echo "PASS: run-swebench-batch phase3 tests"
