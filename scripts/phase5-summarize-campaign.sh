#!/usr/bin/env bash
set -euo pipefail

CAMPAIGN_ROOT=""
TARGETS_FILE=""
OUTPUT_PATH=""

usage() {
  cat <<USAGE
Usage: scripts/phase5-summarize-campaign.sh --campaign-root <path> [options]

Required:
  --campaign-root <path>  Campaign run root containing targets/state/reports

Options:
  --targets-file <path>   Target instance list (default: <campaign-root>/targets/unresolved_ids.txt)
  --output <path>         Summary output path (default: <campaign-root>/reports/final_summary.json)
  -h, --help              Show this help message

Output:
  JSON summary with required bucket counts:
  - resolved_by_phase5
  - unresolved_agent_failure
  - unresolved_infra_or_container
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
    --output)
      [[ $# -ge 2 ]] || { error "--output requires a value"; exit 2; }
      OUTPUT_PATH="$2"
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

CAMPAIGN_ROOT="$(absolute_path_from_pwd "$CAMPAIGN_ROOT")"
STATE_DIR="$CAMPAIGN_ROOT/state"
REPORT_DIR="$CAMPAIGN_ROOT/reports"
ATTEMPTS_PATH="$STATE_DIR/attempts.jsonl"
LATEST_PATH="$STATE_DIR/instance_latest.json"

if [[ -z "$TARGETS_FILE" ]]; then
  TARGETS_FILE="$CAMPAIGN_ROOT/targets/unresolved_ids.txt"
else
  TARGETS_FILE="$(absolute_path_from_pwd "$TARGETS_FILE")"
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$REPORT_DIR/final_summary.json"
else
  OUTPUT_PATH="$(absolute_path_from_pwd "$OUTPUT_PATH")"
fi

if [[ ! -f "$TARGETS_FILE" ]]; then
  error "targets file not found: $TARGETS_FILE"
  exit 1
fi

if [[ ! -f "$ATTEMPTS_PATH" ]]; then
  error "attempt history not found: $ATTEMPTS_PATH"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

python3 - "$CAMPAIGN_ROOT" "$TARGETS_FILE" "$ATTEMPTS_PATH" "$LATEST_PATH" "$OUTPUT_PATH" <<'PY'
import datetime
import json
import pathlib
import sys

campaign_root = pathlib.Path(sys.argv[1])
targets_path = pathlib.Path(sys.argv[2])
attempts_path = pathlib.Path(sys.argv[3])
latest_path = pathlib.Path(sys.argv[4])
output_path = pathlib.Path(sys.argv[5])

target_ids = []
seen_ids = set()
for raw_line in targets_path.read_text(encoding="utf-8").splitlines():
    value = raw_line.strip()
    if not value or value.startswith("#"):
        continue
    if value in seen_ids:
        continue
    seen_ids.add(value)
    target_ids.append(value)

if not target_ids:
    raise SystemExit(f"no target instance IDs found in {targets_path}")

attempt_rows_by_instance = {}
for line_number, raw_line in enumerate(attempts_path.read_text(encoding="utf-8").splitlines(), start=1):
    line = raw_line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"invalid JSON in {attempts_path} at line {line_number}: {exc.msg}"
        ) from exc

    if not isinstance(row, dict):
        continue
    instance_id = row.get("instance_id")
    if not isinstance(instance_id, str) or not instance_id:
        continue
    attempt_rows_by_instance.setdefault(instance_id, []).append(row)

if latest_path.exists():
    try:
        latest_payload = json.loads(latest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {latest_path}: {exc.msg}") from exc
    if not isinstance(latest_payload, dict):
        latest_payload = {}
else:
    latest_payload = {}


def as_text(value):
    return value if isinstance(value, str) else ""


def pick_latest_attempt(instance_id):
    rows = attempt_rows_by_instance.get(instance_id, [])
    if not rows:
        return None

    preferred_attempt_id = ""
    latest_entry = latest_payload.get(instance_id)
    if isinstance(latest_entry, dict):
        preferred_attempt_id = as_text(latest_entry.get("attempt_id"))

    if preferred_attempt_id:
        for row in rows:
            if as_text(row.get("attempt_id")) == preferred_attempt_id:
                return row

    return rows[-1]


counts = {
    "total_targets": len(target_ids),
    "attempted_instances": 0,
    "resolved_by_phase5": 0,
    "unresolved_agent_failure": 0,
    "unresolved_infra_or_container": 0,
    "not_attempted": 0,
}

classification_report = {
    "resolved_by_phase5": [],
    "unresolved_agent_failure": [],
    "unresolved_infra_or_container": [],
    "not_attempted": [],
}

instance_rows = []
for instance_id in target_ids:
    row = pick_latest_attempt(instance_id)
    if row is None:
        counts["not_attempted"] += 1
        classification_report["not_attempted"].append(instance_id)
        instance_rows.append(
            {
                "instance_id": instance_id,
                "attempt_id": "",
                "prediction_status": "not_attempted",
                "patch_non_empty": False,
                "evaluation_result": "not_run",
                "classification": "not_attempted",
                "summary_bucket": "not_attempted",
            }
        )
        continue

    counts["attempted_instances"] += 1

    attempt_id = as_text(row.get("attempt_id"))
    prediction = row.get("prediction")
    if not isinstance(prediction, dict):
        prediction = {}
    evaluation = row.get("evaluation")
    if not isinstance(evaluation, dict):
        evaluation = {}

    prediction_status = as_text(prediction.get("status")) or "unknown"
    patch_non_empty = bool(prediction.get("patch_non_empty"))
    evaluation_result = as_text(evaluation.get("result")) or "not_run"
    classification = as_text(row.get("classification")) or "infra_unclassified"

    if classification == "resolved" or evaluation_result == "resolved":
        summary_bucket = "resolved_by_phase5"
        counts["resolved_by_phase5"] += 1
    elif classification == "agent_failure" or evaluation_result == "unresolved":
        summary_bucket = "unresolved_agent_failure"
        counts["unresolved_agent_failure"] += 1
    else:
        summary_bucket = "unresolved_infra_or_container"
        counts["unresolved_infra_or_container"] += 1

    classification_report[summary_bucket].append(instance_id)
    instance_rows.append(
        {
            "instance_id": instance_id,
            "attempt_id": attempt_id,
            "prediction_status": prediction_status,
            "patch_non_empty": patch_non_empty,
            "evaluation_result": evaluation_result,
            "classification": classification,
            "summary_bucket": summary_bucket,
            "attempt_finished_at": as_text(row.get("attempt_finished_at")),
            "container_fix_id": row.get("container_fix_id"),
        }
    )

summary = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "campaign_root": str(campaign_root),
    "targets_file": str(targets_path),
    "attempts_file": str(attempts_path),
    "instance_latest_file": str(latest_path),
    "counts": counts,
    "classification_report": classification_report,
    "instances": instance_rows,
}

output_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

print(f"campaign_root={campaign_root}")
print(f"targets_file={targets_path}")
print(f"attempts_file={attempts_path}")
print(f"summary_path={output_path}")
print(f"total_targets={counts['total_targets']}")
print(f"attempted_instances={counts['attempted_instances']}")
print(f"resolved_by_phase5={counts['resolved_by_phase5']}")
print(f"unresolved_agent_failure={counts['unresolved_agent_failure']}")
print(f"unresolved_infra_or_container={counts['unresolved_infra_or_container']}")
print(f"not_attempted={counts['not_attempted']}")
PY
