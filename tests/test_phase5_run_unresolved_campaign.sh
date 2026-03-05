#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-run-unresolved-campaign.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/phase5-run-unresolved-campaign.sh"
  chmod +x "$tmpdir/scripts/phase5-run-unresolved-campaign.sh"

  cat > "$tmpdir/scripts/start-swebench.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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
[[ -n "$MAX_LOOPS" ]] || { echo "missing --max-loops" >&2; exit 2; }
[[ -n "${FAKE_START_INVOCATIONS_FILE:-}" ]] || { echo "FAKE_START_INVOCATIONS_FILE is required" >&2; exit 2; }

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
  ERROR_LOG="runtime log for ${INSTANCE_ID}"
  MODEL_PATCH=""
  EXIT_CODE=1
elif instance_in_csv "$INSTANCE_ID" "${FAKE_START_INCOMPLETE_IDS:-}"; then
  STATUS="incomplete"
  FAILURE_REASON_CODE="incomplete"
  FAILURE_REASON_DETAIL="forced incomplete for ${INSTANCE_ID}"
  MODEL_PATCH=""
  EXIT_CODE=20
elif instance_in_csv "$INSTANCE_ID" "${FAKE_START_EMPTY_PATCH_IDS:-}"; then
  MODEL_PATCH=""
fi

mkdir -p "$OUTPUT_DIR" "$MANIFEST_DIR"
printf '%s|%s|%s|%s\n' "$INSTANCE_ID" "$OUTPUT_DIR" "$MANIFEST_DIR" "$MAX_LOOPS" >> "$FAKE_START_INVOCATIONS_FILE"
if [[ -n "${FAKE_PHASE_TRACE_FILE:-}" ]]; then
  printf 'predict|%s\n' "$INSTANCE_ID" >> "$FAKE_PHASE_TRACE_FILE"
fi

python3 - "$OUTPUT_DIR/${INSTANCE_ID}.pred" "$INSTANCE_ID" "$MODEL_PATCH" <<'PY'
import json
import pathlib
import sys

pred_path, instance_id, model_patch = sys.argv[1:]
payload = {
    "model_name_or_path": "qwen3-coder-next-FP8,codex,ralph",
    "instance_id": instance_id,
    "model_patch": model_patch,
}
pathlib.Path(pred_path).write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
PY

if [[ -n "$MODEL_PATCH" ]]; then
  printf '%s\n' "$MODEL_PATCH" > "$OUTPUT_DIR/${INSTANCE_ID}.patch"
else
  : > "$OUTPUT_DIR/${INSTANCE_ID}.patch"
fi

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

exit "$EXIT_CODE"
EOF
  chmod +x "$tmpdir/scripts/start-swebench.sh"

  cat > "$tmpdir/scripts/phase5-run-evals-sequential.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CAMPAIGN_ROOT=""
TARGETS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaign-root)
      CAMPAIGN_ROOT="$2"
      shift 2
      ;;
    --targets-file)
      TARGETS_FILE="$2"
      shift 2
      ;;
    --retry-all|--dataset-name|--max-workers|--namespace|--arch|--run-id-prefix)
      if [[ "$1" == "--retry-all" ]]; then
        shift
      else
        shift 2
      fi
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$CAMPAIGN_ROOT" ]] || { echo "missing --campaign-root" >&2; exit 2; }
[[ -n "$TARGETS_FILE" ]] || { echo "missing --targets-file" >&2; exit 2; }
[[ -n "${FAKE_IMMEDIATE_EVAL_INVOCATIONS_FILE:-}" ]] || { echo "FAKE_IMMEDIATE_EVAL_INVOCATIONS_FILE is required" >&2; exit 2; }

INSTANCE_ID="$(awk 'NF { print $1; exit }' "$TARGETS_FILE")"
[[ -n "$INSTANCE_ID" ]] || { echo "targets file empty: $TARGETS_FILE" >&2; exit 2; }
printf '%s\n' "$INSTANCE_ID" >> "$FAKE_IMMEDIATE_EVAL_INVOCATIONS_FILE"
if [[ -n "${FAKE_PHASE_TRACE_FILE:-}" ]]; then
  printf 'eval|%s\n' "$INSTANCE_ID" >> "$FAKE_PHASE_TRACE_FILE"
fi

result_for_instance() {
  local target="$1"
  local csv="${FAKE_IMMEDIATE_EVAL_RESULTS:-}"
  local pair=""
  local key=""
  local value=""
  IFS=',' read -r -a pairs <<< "$csv"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ "$key" == "$target" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  printf 'unresolved'
}

RESULT="$(result_for_instance "$INSTANCE_ID")"
CLASSIFICATION="infra_unclassified"
if [[ "$RESULT" == "resolved" ]]; then
  CLASSIFICATION="resolved"
elif [[ "$RESULT" == "unresolved" ]]; then
  CLASSIFICATION="agent_failure"
else
  RESULT="eval_error"
  CLASSIFICATION="infra_unclassified"
fi

python3 - "$CAMPAIGN_ROOT" "$INSTANCE_ID" "$RESULT" "$CLASSIFICATION" <<'PY'
import json
import pathlib
import sys

campaign_root = pathlib.Path(sys.argv[1])
instance_id = sys.argv[2]
evaluation_result = sys.argv[3]
classification = sys.argv[4]

attempts_path = campaign_root / "state" / "attempts.jsonl"
latest_path = campaign_root / "state" / "instance_latest.json"
eval_result_path = campaign_root / "state" / "evals" / f"{instance_id}.eval.json"

rows = []
for raw_line in attempts_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line:
        continue
    rows.append(json.loads(line))

target_idx = None
for idx, row in enumerate(rows):
    if row.get("instance_id") == instance_id:
        target_idx = idx

if target_idx is None:
    raise SystemExit(f"missing attempt row for {instance_id}")

row = rows[target_idx]
evaluation = row.get("evaluation")
if not isinstance(evaluation, dict):
    evaluation = {}
evaluation["executed"] = True
evaluation["result"] = evaluation_result
row["evaluation"] = evaluation
row["classification"] = classification
rows[target_idx] = row

attempts_path.write_text(
    "\n".join(json.dumps(item, separators=(",", ":")) for item in rows) + "\n",
    encoding="utf-8",
)

if latest_path.exists():
    latest = json.loads(latest_path.read_text(encoding="utf-8"))
else:
    latest = {}
entry = latest.get(instance_id, {"instance_id": instance_id})
entry["attempt_id"] = row.get("attempt_id")
entry["evaluation_result"] = evaluation_result
entry["classification"] = classification
latest[instance_id] = entry
latest_path.write_text(json.dumps(latest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

eval_result_path.parent.mkdir(parents=True, exist_ok=True)
eval_result_path.write_text(
    json.dumps(
        {
            "instance_id": instance_id,
            "evaluation_result": evaluation_result,
            "detail": f"fake immediate eval for {instance_id}",
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
PY

if [[ "$RESULT" == "eval_error" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$tmpdir/scripts/phase5-run-evals-sequential.sh"
  echo "$tmpdir"
}

write_targets_file() {
  local path="$1"
  cat > "$path" <<'EOF'
repo__alpha-1
repo__beta-2
repo__gamma-3
repo__beta-2
EOF
}

run_case_sequential_attempts_and_resume() {
  local tmpdir
  local campaign_root
  local targets_file
  local invocations_file
  local attempts_file
  local latest_file
  tmpdir="$(make_isolated_root)"

  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  targets_file="$campaign_root/targets/unresolved_ids.txt"
  invocations_file="$tmpdir/invocations.log"
  attempts_file="$campaign_root/state/attempts.jsonl"
  latest_file="$campaign_root/state/instance_latest.json"
  mkdir -p "$(dirname "$targets_file")"
  write_targets_file "$targets_file"

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" FAKE_START_FAIL_IDS="repo__beta-2" \
      ./scripts/phase5-run-unresolved-campaign.sh --campaign-root "$campaign_root" --max-loops 9
  ) > /tmp/phase5-campaign-test.out 2> /tmp/phase5-campaign-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "campaign should exit 1 when one instance fails prediction"
  [[ -f "$attempts_file" ]] || fail "attempts.jsonl should be created"
  [[ -f "$latest_file" ]] || fail "instance_latest.json should be created"

  python3 - "$invocations_file" "$attempts_file" "$latest_file" "$campaign_root" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
attempts_path = pathlib.Path(sys.argv[2])
latest_path = pathlib.Path(sys.argv[3])
campaign_root = pathlib.Path(sys.argv[4])

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 3, invocations
expected_ids = ["repo__alpha-1", "repo__beta-2", "repo__gamma-3"]

seen_ids = []
for row in invocations:
    instance_id, output_dir, manifest_dir, max_loops = row.split("|")
    seen_ids.append(instance_id)
    assert pathlib.Path(output_dir) == campaign_root / "instances" / instance_id
    assert pathlib.Path(manifest_dir) == campaign_root
    assert max_loops == "9"
assert seen_ids == expected_ids, seen_ids

attempt_rows = [json.loads(line) for line in attempts_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(attempt_rows) == 3, attempt_rows
status_by_id = {}
for row in attempt_rows:
    iid = row["instance_id"]
    status_by_id[iid] = row["prediction"]["status"]
    assert row["attempt_id"] == f"{iid}-attempt-001"
    assert row["evaluation"]["executed"] is False
    assert row["evaluation"]["result"] == "not_run"
    assert row["classification"] == "infra_unclassified"

assert status_by_id == {
    "repo__alpha-1": "success",
    "repo__beta-2": "failed",
    "repo__gamma-3": "success",
}, status_by_id

latest = json.loads(latest_path.read_text(encoding="utf-8"))
assert latest["repo__alpha-1"]["attempt_id"] == "repo__alpha-1-attempt-001"
assert latest["repo__beta-2"]["prediction_status"] == "failed"
assert latest["repo__gamma-3"]["prediction_status"] == "success"
PY

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" \
      ./scripts/phase5-run-unresolved-campaign.sh --campaign-root "$campaign_root"
  ) > /tmp/phase5-campaign-test.out 2> /tmp/phase5-campaign-test.err
  local resume_status=$?
  set -e

  assert_eq "0" "$resume_status" "resume run should skip terminal attempts and exit 0"

  python3 - "$invocations_file" "$attempts_file" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
attempts_path = pathlib.Path(sys.argv[2])

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 3, invocations

attempt_rows = [json.loads(line) for line in attempts_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(attempt_rows) == 3, attempt_rows
PY

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" \
      ./scripts/phase5-run-unresolved-campaign.sh --campaign-root "$campaign_root" --retry-all --container-fix-id fix-001
  ) > /tmp/phase5-campaign-test.out 2> /tmp/phase5-campaign-test.err
  local retry_status=$?
  set -e

  assert_eq "0" "$retry_status" "retry-all run should execute and succeed when fake runner has no failures"

  python3 - "$invocations_file" "$attempts_file" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
attempts_path = pathlib.Path(sys.argv[2])

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 6, invocations
retry_ids = [line.split("|")[0] for line in invocations[-3:]]
assert retry_ids == ["repo__alpha-1", "repo__beta-2", "repo__gamma-3"], retry_ids

attempt_rows = [json.loads(line) for line in attempts_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(attempt_rows) == 6, attempt_rows

second_attempt_ids = {row["instance_id"]: row["attempt_id"] for row in attempt_rows[-3:]}
assert second_attempt_ids == {
    "repo__alpha-1": "repo__alpha-1-attempt-002",
    "repo__beta-2": "repo__beta-2-attempt-002",
    "repo__gamma-3": "repo__gamma-3-attempt-002",
}, second_attempt_ids

for row in attempt_rows[:3]:
    assert row["container_fix_id"] is None
for row in attempt_rows[-3:]:
    assert row["container_fix_id"] == "fix-001"
PY
}

run_case_immediate_eval_ordering() {
  local tmpdir
  local campaign_root
  local targets_file
  local invocations_file
  local eval_invocations_file
  local trace_file
  local attempts_file
  local latest_file
  tmpdir="$(make_isolated_root)"

  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-immediate"
  targets_file="$campaign_root/targets/unresolved_ids.txt"
  invocations_file="$tmpdir/immediate-invocations.log"
  eval_invocations_file="$tmpdir/immediate-evals.log"
  trace_file="$tmpdir/phase-trace.log"
  attempts_file="$campaign_root/state/attempts.jsonl"
  latest_file="$campaign_root/state/instance_latest.json"
  mkdir -p "$(dirname "$targets_file")"
  write_targets_file "$targets_file"

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" \
    FAKE_IMMEDIATE_EVAL_INVOCATIONS_FILE="$eval_invocations_file" \
    FAKE_PHASE_TRACE_FILE="$trace_file" \
    FAKE_START_EMPTY_PATCH_IDS="repo__beta-2" \
    FAKE_IMMEDIATE_EVAL_RESULTS="repo__alpha-1=resolved,repo__gamma-3=unresolved" \
      ./scripts/phase5-run-unresolved-campaign.sh \
        --campaign-root "$campaign_root" \
        --immediate-eval
  ) > /tmp/phase5-campaign-immediate-test.out 2> /tmp/phase5-campaign-immediate-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "immediate-eval run should succeed for resolved/unresolved eval outcomes"

  python3 - "$invocations_file" "$eval_invocations_file" "$trace_file" "$attempts_file" "$latest_file" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
eval_invocations_path = pathlib.Path(sys.argv[2])
trace_path = pathlib.Path(sys.argv[3])
attempts_path = pathlib.Path(sys.argv[4])
latest_path = pathlib.Path(sys.argv[5])

prediction_order = [line.split("|")[0] for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert prediction_order == ["repo__alpha-1", "repo__beta-2", "repo__gamma-3"], prediction_order

eval_order = [line.strip() for line in eval_invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert eval_order == ["repo__alpha-1", "repo__gamma-3"], eval_order

trace = [line.strip() for line in trace_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert trace == [
    "predict|repo__alpha-1",
    "eval|repo__alpha-1",
    "predict|repo__beta-2",
    "predict|repo__gamma-3",
    "eval|repo__gamma-3",
], trace

rows = {}
for line in attempts_path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    rows[row["instance_id"]] = row

assert rows["repo__alpha-1"]["evaluation"]["executed"] is True
assert rows["repo__alpha-1"]["evaluation"]["result"] == "resolved"
assert rows["repo__alpha-1"]["classification"] == "resolved"

assert rows["repo__beta-2"]["evaluation"]["executed"] is False
assert rows["repo__beta-2"]["evaluation"]["result"] == "not_run"
assert rows["repo__beta-2"]["classification"] == "infra_unclassified"

assert rows["repo__gamma-3"]["evaluation"]["executed"] is True
assert rows["repo__gamma-3"]["evaluation"]["result"] == "unresolved"
assert rows["repo__gamma-3"]["classification"] == "agent_failure"

latest = json.loads(latest_path.read_text(encoding="utf-8"))
assert latest["repo__alpha-1"]["evaluation_result"] == "resolved"
assert latest["repo__beta-2"]["evaluation_result"] == "not_run"
assert latest["repo__gamma-3"]["evaluation_result"] == "unresolved"
PY
}

run_case_default_campaign_root() {
  local tmpdir
  local default_campaign_root
  local targets_file
  local invocations_file
  local attempts_file
  tmpdir="$(make_isolated_root)"

  default_campaign_root="$tmpdir/results/phase5/unresolved-campaign/current"
  targets_file="$default_campaign_root/targets/unresolved_ids.txt"
  invocations_file="$tmpdir/default-root-invocations.log"
  attempts_file="$default_campaign_root/state/attempts.jsonl"

  mkdir -p "$(dirname "$targets_file")"
  cat > "$targets_file" <<'EOF'
repo__single-1
EOF

  set +e
  (
    cd "$tmpdir"
    FAKE_START_INVOCATIONS_FILE="$invocations_file" \
      ./scripts/phase5-run-unresolved-campaign.sh
  ) > /tmp/phase5-campaign-default-root-test.out 2> /tmp/phase5-campaign-default-root-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "campaign should run successfully with default campaign root"
  [[ -f "$attempts_file" ]] || fail "attempts.jsonl should be created under default campaign root"

  python3 - "$invocations_file" "$default_campaign_root" "$attempts_file" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
default_campaign_root = pathlib.Path(sys.argv[2])
attempts_path = pathlib.Path(sys.argv[3])

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 1, invocations
instance_id, output_dir, manifest_dir, _max_loops = invocations[0].split("|")
assert instance_id == "repo__single-1"
assert pathlib.Path(output_dir) == default_campaign_root / "instances" / "repo__single-1"
assert pathlib.Path(manifest_dir) == default_campaign_root

rows = [json.loads(line) for line in attempts_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(rows) == 1, rows
assert rows[0]["instance_id"] == "repo__single-1"
assert rows[0]["attempt_id"] == "repo__single-1-attempt-001"
PY
}

run_case_sequential_attempts_and_resume
run_case_immediate_eval_ordering
run_case_default_campaign_root

echo "PASS: phase5-run-unresolved-campaign"
