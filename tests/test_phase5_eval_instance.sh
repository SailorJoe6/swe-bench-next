#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-eval-instance.sh"

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

make_isolated_root() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/scripts"
  cp "$SCRIPT" "$tmpdir/scripts/phase5-eval-instance.sh"
  chmod +x "$tmpdir/scripts/phase5-eval-instance.sh"

  cat > "$tmpdir/fake-python.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == "-m" ]] || { echo "expected -m" >&2; exit 2; }
[[ "$2" == "swebench.harness.run_evaluation" ]] || { echo "unexpected module: $2" >&2; exit 2; }
shift 2

DATASET_NAME=""
PREDICTIONS_PATH=""
MAX_WORKERS=""
RUN_ID=""
ARCH=""
NAMESPACE=""
REPORT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset_name)
      DATASET_NAME="$2"
      shift 2
      ;;
    --split)
      shift 2
      ;;
    --predictions_path)
      PREDICTIONS_PATH="$2"
      shift 2
      ;;
    --max_workers)
      MAX_WORKERS="$2"
      shift 2
      ;;
    --run_id)
      RUN_ID="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --report_dir)
      REPORT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "${FAKE_EVAL_INVOCATIONS_FILE:-}" ]] || { echo "FAKE_EVAL_INVOCATIONS_FILE is required" >&2; exit 2; }
printf '%s|%s|%s|%s|%s|%s|%s\n' \
  "$DATASET_NAME" "$PREDICTIONS_PATH" "$MAX_WORKERS" "$RUN_ID" "$ARCH" "$NAMESPACE" "$REPORT_DIR" \
  >> "$FAKE_EVAL_INVOCATIONS_FILE"

if [[ "${FAKE_EVAL_MODE:-unresolved}" == "harness_fail" ]]; then
  echo "simulated harness failure" >&2
  exit 7
fi

python3 - "$PREDICTIONS_PATH" "$REPORT_DIR" "$RUN_ID" "${FAKE_EVAL_MODE:-unresolved}" <<'PY'
import json
import pathlib
import sys

predictions_path = pathlib.Path(sys.argv[1])
report_dir = pathlib.Path(sys.argv[2])
run_id = sys.argv[3]
mode = sys.argv[4]
cwd = pathlib.Path.cwd()

instance_id = None
for raw_line in predictions_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line:
        continue
    payload = json.loads(line)
    if isinstance(payload, dict) and isinstance(payload.get("instance_id"), str):
        instance_id = payload["instance_id"]
        break

if not instance_id:
    raise SystemExit("prediction did not include instance_id")

resolved_ids = []
unresolved_ids = []
error_ids = []

if mode == "resolved":
    resolved_ids = [instance_id]
elif mode == "unresolved":
    unresolved_ids = [instance_id]
elif mode == "eval_error":
    error_ids = [instance_id]
else:
    raise SystemExit(f"unknown mode: {mode}")

summary = {
    "total_instances": 300,
    "submitted_instances": 1,
    "completed_instances": 1,
    "resolved_instances": len(resolved_ids),
    "unresolved_instances": len(unresolved_ids),
    "error_instances": len(error_ids),
    "resolved_ids": resolved_ids,
    "unresolved_ids": unresolved_ids,
    "error_ids": error_ids,
}

report_dir.mkdir(parents=True, exist_ok=True)
summary_path = cwd / f"fake-model.{run_id}.json"
summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY
EOF
  chmod +x "$tmpdir/fake-python.sh"

  echo "$tmpdir"
}

write_prediction() {
  local path="$1"
  local instance_id="$2"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$instance_id" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
instance_id = sys.argv[2]
payload = {
    "model_name_or_path": "qwen3-coder-next-FP8,codex,ralph",
    "instance_id": instance_id,
    "model_patch": "fake patch",
}
path.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

run_case_unresolved_success() {
  local tmpdir
  local campaign_root
  local instance_id
  local predictions_path
  local invocations_path
  local result_path
  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  instance_id="repo__alpha-1"
  predictions_path="$campaign_root/instances/$instance_id/$instance_id.pred"
  invocations_path="$tmpdir/invocations.log"
  result_path="$campaign_root/state/evals/${instance_id}.eval.json"

  write_prediction "$predictions_path" "$instance_id"

  set +e
  (
    cd "$tmpdir"
    SWE_BENCH_PYTHON_BIN="$tmpdir/fake-python.sh" \
    FAKE_EVAL_INVOCATIONS_FILE="$invocations_path" \
    FAKE_EVAL_MODE="unresolved" \
      ./scripts/phase5-eval-instance.sh --campaign-root "$campaign_root" --instance-id "$instance_id"
  ) > /tmp/phase5-eval-instance-test.out 2> /tmp/phase5-eval-instance-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "eval wrapper should succeed for unresolved result"
  [[ -f "$result_path" ]] || fail "result file was not written"
  [[ -f "$campaign_root/reports/eval/$instance_id/run_evaluation.log" ]] || fail "run log was not written"
  rg -F -q "evaluation_result=unresolved" /tmp/phase5-eval-instance-test.out || fail "stdout did not include unresolved result"

  python3 - "$invocations_path" "$result_path" "$predictions_path" "$campaign_root" "$instance_id" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
result_path = pathlib.Path(sys.argv[2])
predictions_path = pathlib.Path(sys.argv[3])
campaign_root = pathlib.Path(sys.argv[4])
instance_id = sys.argv[5]

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 1, invocations
dataset_name, predictions_arg, max_workers, run_id, arch, namespace, report_dir = invocations[0].split("|")
assert dataset_name == "SWE-bench/SWE-bench_Multilingual"
eval_input_path = pathlib.Path(predictions_arg)
assert eval_input_path.suffix == ".jsonl"
assert eval_input_path == campaign_root / "reports" / "eval" / instance_id / f"predictions.phase5-eval-{instance_id}.jsonl"
assert eval_input_path.read_text(encoding="utf-8") == predictions_path.read_text(encoding="utf-8")
assert max_workers == "1"
assert run_id == f"phase5-eval-{instance_id}"
assert arch == "arm64"
assert namespace == "none"
assert pathlib.Path(report_dir) == campaign_root / "reports" / "eval" / instance_id

result = json.loads(result_path.read_text(encoding="utf-8"))
assert result["instance_id"] == instance_id
assert result["evaluation_result"] == "unresolved"
assert result["harness_exit_code"] == 0
assert pathlib.Path(result["predictions_path"]) == predictions_path
assert pathlib.Path(result["report_dir"]) == campaign_root / "reports" / "eval" / instance_id
assert pathlib.Path(result["summary_path"]) == campaign_root / "evaluations" / f"fake-model.phase5-eval-{instance_id}.json"
PY
}

run_case_harness_failure_is_nonzero() {
  local tmpdir
  local campaign_root
  local instance_id
  local predictions_path
  local invocations_path
  local result_path
  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-b"
  instance_id="repo__beta-2"
  predictions_path="$campaign_root/instances/$instance_id/$instance_id.pred"
  invocations_path="$tmpdir/invocations.log"
  result_path="$campaign_root/state/evals/${instance_id}.eval.json"

  write_prediction "$predictions_path" "$instance_id"

  set +e
  (
    cd "$tmpdir"
    SWE_BENCH_PYTHON_BIN="$tmpdir/fake-python.sh" \
    FAKE_EVAL_INVOCATIONS_FILE="$invocations_path" \
    FAKE_EVAL_MODE="harness_fail" \
      ./scripts/phase5-eval-instance.sh --campaign-root "$campaign_root" --instance-id "$instance_id"
  ) > /tmp/phase5-eval-instance-test.out 2> /tmp/phase5-eval-instance-test.err
  local status=$?
  set -e

  assert_eq "7" "$status" "eval wrapper should return harness non-zero exit code"
  [[ -f "$result_path" ]] || fail "result file should still be written on harness failure"
  rg -F -q "run_evaluation failed" /tmp/phase5-eval-instance-test.err || fail "stderr should include harness failure details"

  python3 - "$result_path" "$campaign_root" "$instance_id" <<'PY'
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
campaign_root = pathlib.Path(sys.argv[2])
instance_id = sys.argv[3]

result = json.loads(result_path.read_text(encoding="utf-8"))
assert result["instance_id"] == instance_id
assert result["evaluation_result"] == "eval_error"
assert result["harness_exit_code"] == 7
assert result["detail"] == "run_evaluation exited non-zero"
assert pathlib.Path(result["run_log"]) == campaign_root / "reports" / "eval" / instance_id / "run_evaluation.log"
PY
}

run_case_unresolved_success
run_case_harness_failure_is_nonzero

echo "PASS: phase5-eval-instance"
