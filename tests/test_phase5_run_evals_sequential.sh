#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-run-evals-sequential.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/phase5-run-evals-sequential.sh"
  chmod +x "$tmpdir/scripts/phase5-run-evals-sequential.sh"

  cat > "$tmpdir/scripts/phase5-eval-instance.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CAMPAIGN_ROOT=""
INSTANCE_ID=""
PREDICTIONS_PATH=""
RUN_ID=""
DATASET_NAME=""
MAX_WORKERS=""
NAMESPACE=""
ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaign-root)
      CAMPAIGN_ROOT="$2"
      shift 2
      ;;
    --instance-id)
      INSTANCE_ID="$2"
      shift 2
      ;;
    --predictions-path)
      PREDICTIONS_PATH="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    --dataset-name)
      DATASET_NAME="$2"
      shift 2
      ;;
    --max-workers)
      MAX_WORKERS="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "${FAKE_EVAL_INVOCATIONS_FILE:-}" ]] || { echo "FAKE_EVAL_INVOCATIONS_FILE is required" >&2; exit 2; }
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
  "$INSTANCE_ID" "$PREDICTIONS_PATH" "$RUN_ID" "$DATASET_NAME" "$MAX_WORKERS" "$NAMESPACE" "$ARCH" "$CAMPAIGN_ROOT" \
  >> "$FAKE_EVAL_INVOCATIONS_FILE"

result_for_instance() {
  local target="$1"
  local csv="${FAKE_EVAL_RESULTS:-}"
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
DETAIL="simulated result for ${INSTANCE_ID}"
EXIT_CODE=0

if [[ "$RESULT" == "eval_error" ]]; then
  EXIT_CODE=9
fi

RESULT_PATH="$CAMPAIGN_ROOT/state/evals/${INSTANCE_ID}.eval.json"
mkdir -p "$(dirname "$RESULT_PATH")"

python3 - "$RESULT_PATH" "$INSTANCE_ID" "$RUN_ID" "$PREDICTIONS_PATH" "$RESULT" "$DETAIL" "$EXIT_CODE" <<'PY'
import json
import pathlib
import sys

(
    result_path_raw,
    instance_id,
    run_id,
    predictions_path,
    evaluation_result,
    detail,
    exit_code_raw,
) = sys.argv[1:]

result_path = pathlib.Path(result_path_raw)
payload = {
    "instance_id": instance_id,
    "run_id": run_id,
    "predictions_path": predictions_path,
    "report_dir": str(result_path.parent),
    "run_log": str(result_path.parent / "run_evaluation.log"),
    "summary_path": str(result_path.parent / f"summary.{run_id}.json"),
    "evaluation_result": evaluation_result,
    "harness_exit_code": int(exit_code_raw),
    "detail": detail,
}
result_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

if [[ "$EXIT_CODE" -ne 0 ]]; then
  echo "simulated eval failure for $INSTANCE_ID" >&2
fi
exit "$EXIT_CODE"
EOF
  chmod +x "$tmpdir/scripts/phase5-eval-instance.sh"

  echo "$tmpdir"
}

write_campaign_fixture() {
  local campaign_root="$1"
  local targets_file="$campaign_root/targets/unresolved_ids.txt"
  local attempts_file="$campaign_root/state/attempts.jsonl"
  local latest_file="$campaign_root/state/instance_latest.json"

  mkdir -p "$campaign_root/targets" "$campaign_root/state" "$campaign_root/instances"
  cat > "$targets_file" <<'EOF'
repo__alpha-1
repo__beta-2
repo__gamma-3
repo__delta-4
EOF

  python3 - "$campaign_root" "$attempts_file" "$latest_file" <<'PY'
import json
import pathlib
import sys

campaign_root = pathlib.Path(sys.argv[1])
attempts_path = pathlib.Path(sys.argv[2])
latest_path = pathlib.Path(sys.argv[3])

instances = [
    ("repo__alpha-1", True, "not_run", "infra_unclassified"),
    ("repo__beta-2", False, "not_run", "infra_unclassified"),
    ("repo__gamma-3", True, "resolved", "resolved"),
    ("repo__delta-4", True, "not_run", "infra_unclassified"),
]

rows = []
latest = {}

for instance_id, patch_non_empty, eval_result, classification in instances:
    instance_dir = campaign_root / "instances" / instance_id
    instance_dir.mkdir(parents=True, exist_ok=True)
    pred_path = instance_dir / f"{instance_id}.pred"
    pred_payload = {
        "model_name_or_path": "qwen3-coder-next-FP8,codex,ralph",
        "instance_id": instance_id,
        "model_patch": "fake patch" if patch_non_empty else "",
    }
    pred_path.write_text(json.dumps(pred_payload, separators=(",", ":")) + "\n", encoding="utf-8")
    patch_path = instance_dir / f"{instance_id}.patch"
    patch_path.write_text("fake patch\n" if patch_non_empty else "", encoding="utf-8")

    attempt_id = f"{instance_id}-attempt-001"
    row = {
        "instance_id": instance_id,
        "attempt_id": attempt_id,
        "attempt_started_at": "2026-03-02T00:00:00Z",
        "attempt_finished_at": "2026-03-02T00:01:00Z",
        "prediction": {
            "status": "success",
            "patch_path": str(patch_path),
            "pred_path": str(pred_path),
            "patch_non_empty": patch_non_empty,
            "failure_reason_code": None,
            "failure_reason_detail": "",
            "error_log": "",
            "instance_output_dir": str(instance_dir),
        },
        "evaluation": {
            "executed": eval_result != "not_run",
            "result": eval_result,
        },
        "classification": classification,
        "container_fix_id": None,
        "notes": "fixture row",
    }
    rows.append(row)

    latest[instance_id] = {
        "instance_id": instance_id,
        "attempt_id": attempt_id,
        "attempt_finished_at": "2026-03-02T00:01:00Z",
        "prediction_status": "success",
        "patch_non_empty": patch_non_empty,
        "evaluation_result": eval_result,
        "classification": classification,
    }

attempts_path.write_text(
    "\n".join(json.dumps(row, separators=(",", ":")) for row in rows) + "\n",
    encoding="utf-8",
)
latest_path.write_text(json.dumps(latest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

run_case_sequential_eval_and_resume() {
  local tmpdir
  local campaign_root
  local invocations_file
  local attempts_file
  local latest_file
  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  invocations_file="$tmpdir/eval-invocations.log"
  attempts_file="$campaign_root/state/attempts.jsonl"
  latest_file="$campaign_root/state/instance_latest.json"

  write_campaign_fixture "$campaign_root"

  set +e
  (
    cd "$tmpdir"
    FAKE_EVAL_INVOCATIONS_FILE="$invocations_file" \
    FAKE_EVAL_RESULTS="repo__alpha-1=resolved,repo__delta-4=eval_error" \
      ./scripts/phase5-run-evals-sequential.sh --campaign-root "$campaign_root" --max-workers 2
  ) > /tmp/phase5-run-evals-sequential-test.out 2> /tmp/phase5-run-evals-sequential-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "runner should exit 1 when eval_error occurs"

  python3 - "$invocations_file" "$attempts_file" "$latest_file" "$campaign_root" <<'PY'
import json
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
attempts_path = pathlib.Path(sys.argv[2])
latest_path = pathlib.Path(sys.argv[3])
campaign_root = pathlib.Path(sys.argv[4])

invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 2, invocations

first = invocations[0].split("|")
second = invocations[1].split("|")

assert first[0] == "repo__alpha-1", first
assert second[0] == "repo__delta-4", second
assert pathlib.Path(first[1]) == campaign_root / "instances" / "repo__alpha-1" / "repo__alpha-1.pred"
assert pathlib.Path(second[1]) == campaign_root / "instances" / "repo__delta-4" / "repo__delta-4.pred"
assert first[2] == "phase5-eval-repo__alpha-1-attempt-001"
assert second[2] == "phase5-eval-repo__delta-4-attempt-001"
assert first[3] == "SWE-bench/SWE-bench_Multilingual"
assert second[3] == "SWE-bench/SWE-bench_Multilingual"
assert first[4] == "2"
assert second[4] == "2"
assert first[5] == "none"
assert second[5] == "none"
assert first[6] == "arm64"
assert second[6] == "arm64"

rows = {}
for line in attempts_path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    rows[row["instance_id"]] = row

alpha = rows["repo__alpha-1"]
assert alpha["evaluation"]["executed"] is True
assert alpha["evaluation"]["result"] == "resolved"
assert alpha["classification"] == "resolved"

beta = rows["repo__beta-2"]
assert beta["evaluation"]["executed"] is False
assert beta["evaluation"]["result"] == "not_run"

gamma = rows["repo__gamma-3"]
assert gamma["evaluation"]["executed"] is True
assert gamma["evaluation"]["result"] == "resolved"
assert gamma["classification"] == "resolved"

delta = rows["repo__delta-4"]
assert delta["evaluation"]["executed"] is True
assert delta["evaluation"]["result"] == "eval_error"
assert delta["classification"] == "infra_unclassified"
assert delta["evaluation"]["exit_code"] == 9

latest = json.loads(latest_path.read_text(encoding="utf-8"))
assert latest["repo__alpha-1"]["evaluation_result"] == "resolved"
assert latest["repo__alpha-1"]["classification"] == "resolved"
assert latest["repo__delta-4"]["evaluation_result"] == "eval_error"
assert latest["repo__delta-4"]["classification"] == "infra_unclassified"
PY

  set +e
  (
    cd "$tmpdir"
    FAKE_EVAL_INVOCATIONS_FILE="$invocations_file" \
    FAKE_EVAL_RESULTS="repo__alpha-1=resolved,repo__delta-4=eval_error" \
      ./scripts/phase5-run-evals-sequential.sh --campaign-root "$campaign_root"
  ) > /tmp/phase5-run-evals-sequential-test.out 2> /tmp/phase5-run-evals-sequential-test.err
  local resume_status=$?
  set -e

  assert_eq "0" "$resume_status" "resume run should skip already terminal evaluation results"

  python3 - "$invocations_file" <<'PY'
import pathlib
import sys

invocations_path = pathlib.Path(sys.argv[1])
invocations = [line.strip() for line in invocations_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(invocations) == 2, invocations
PY
}

run_case_sequential_eval_and_resume

echo "PASS: phase5-run-evals-sequential"
