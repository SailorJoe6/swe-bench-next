#!/usr/bin/env bash
set -euo pipefail

CAMPAIGN_ROOT=""
NOTE=""
CONTAINER_FIX_ID=""
CONTAINER_FIXES_FILE=""
ATTEMPTS_FILE=""
LATEST_FILE=""
declare -a INSTANCE_IDS=()
declare -a INSTANCE_ID_FILES=()
declare -a ATTEMPT_IDS=()

usage() {
  cat <<USAGE
Usage: scripts/phase5-triage-container-defect.sh --campaign-root <path> --note <text> [selectors] [options]

Required:
  --campaign-root <path>      Campaign run root containing state/
  --note <text>               Triage note describing why these attempts are container defects

Selectors (at least one required):
  --instance-id <id>          Promote latest attempt for this instance (repeatable)
  --instance-ids-file <path>  File with instance IDs (one per line, supports # comments)
  --attempt-id <id>           Promote this explicit attempt ID (repeatable)

Options:
  --container-fix-id <id>     Link promoted attempts to a recorded fix ID
  --container-fixes-file <path>
                              Override fix registry path (default: <campaign-root>/state/container_fixes.jsonl)
  --attempts-file <path>      Override attempts path (default: <campaign-root>/state/attempts.jsonl)
  --latest-file <path>        Override latest index path (default: <campaign-root>/state/instance_latest.json)
  -h, --help                  Show this help message

Behavior:
  - Promotes selected attempts from infra_unclassified to container_porting_defect
  - Requires selected attempts to have evaluation.result=eval_error
  - Updates matching entries in instance_latest.json when selected attempt is latest
  - Appends deterministic triage note in attempts.jsonl for traceability
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --campaign-root)
      [[ $# -ge 2 ]] || { error "--campaign-root requires a value"; exit 2; }
      CAMPAIGN_ROOT="$2"
      shift 2
      ;;
    --note)
      [[ $# -ge 2 ]] || { error "--note requires a value"; exit 2; }
      NOTE="$2"
      shift 2
      ;;
    --instance-id)
      [[ $# -ge 2 ]] || { error "--instance-id requires a value"; exit 2; }
      INSTANCE_IDS+=("$2")
      shift 2
      ;;
    --instance-ids-file)
      [[ $# -ge 2 ]] || { error "--instance-ids-file requires a value"; exit 2; }
      INSTANCE_ID_FILES+=("$2")
      shift 2
      ;;
    --attempt-id)
      [[ $# -ge 2 ]] || { error "--attempt-id requires a value"; exit 2; }
      ATTEMPT_IDS+=("$2")
      shift 2
      ;;
    --container-fix-id)
      [[ $# -ge 2 ]] || { error "--container-fix-id requires a value"; exit 2; }
      CONTAINER_FIX_ID="$2"
      shift 2
      ;;
    --container-fixes-file)
      [[ $# -ge 2 ]] || { error "--container-fixes-file requires a value"; exit 2; }
      CONTAINER_FIXES_FILE="$2"
      shift 2
      ;;
    --attempts-file)
      [[ $# -ge 2 ]] || { error "--attempts-file requires a value"; exit 2; }
      ATTEMPTS_FILE="$2"
      shift 2
      ;;
    --latest-file)
      [[ $# -ge 2 ]] || { error "--latest-file requires a value"; exit 2; }
      LATEST_FILE="$2"
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

if [[ -z "$NOTE" ]]; then
  error "--note is required"
  usage >&2
  exit 2
fi

if [[ "${#INSTANCE_IDS[@]}" -eq 0 && "${#INSTANCE_ID_FILES[@]}" -eq 0 && "${#ATTEMPT_IDS[@]}" -eq 0 ]]; then
  error "at least one selector is required (--instance-id, --instance-ids-file, --attempt-id)"
  usage >&2
  exit 2
fi

CAMPAIGN_ROOT="$(absolute_path_from_pwd "$CAMPAIGN_ROOT")"
if [[ -z "$ATTEMPTS_FILE" ]]; then
  ATTEMPTS_FILE="$CAMPAIGN_ROOT/state/attempts.jsonl"
else
  ATTEMPTS_FILE="$(absolute_path_from_pwd "$ATTEMPTS_FILE")"
fi

if [[ -z "$LATEST_FILE" ]]; then
  LATEST_FILE="$CAMPAIGN_ROOT/state/instance_latest.json"
else
  LATEST_FILE="$(absolute_path_from_pwd "$LATEST_FILE")"
fi

if [[ -z "$CONTAINER_FIXES_FILE" ]]; then
  CONTAINER_FIXES_FILE="$CAMPAIGN_ROOT/state/container_fixes.jsonl"
else
  CONTAINER_FIXES_FILE="$(absolute_path_from_pwd "$CONTAINER_FIXES_FILE")"
fi

if [[ ! -f "$ATTEMPTS_FILE" ]]; then
  error "attempt history not found: $ATTEMPTS_FILE"
  exit 1
fi

if [[ ! -f "$LATEST_FILE" ]]; then
  error "latest state file not found: $LATEST_FILE"
  exit 1
fi

if [[ -n "$CONTAINER_FIX_ID" && ! -f "$CONTAINER_FIXES_FILE" ]]; then
  error "container fixes file not found: $CONTAINER_FIXES_FILE"
  exit 1
fi

instance_input="$(mktemp)"
attempt_input="$(mktemp)"
trap 'rm -f "$instance_input" "$attempt_input"' EXIT

for value in "${INSTANCE_IDS[@]}"; do
  printf '%s\n' "$value" >> "$instance_input"
done

for value in "${ATTEMPT_IDS[@]}"; do
  printf '%s\n' "$value" >> "$attempt_input"
done

if [[ "${#INSTANCE_ID_FILES[@]}" -gt 0 ]]; then
  for source_path in "${INSTANCE_ID_FILES[@]}"; do
    source_abs="$(absolute_path_from_pwd "$source_path")"
    if [[ ! -f "$source_abs" ]]; then
      error "instance IDs file not found: $source_abs"
      exit 1
    fi
    cat "$source_abs" >> "$instance_input"
    printf '\n' >> "$instance_input"
  done
fi

TRIAGED_AT="$(timestamp_utc)"

python3 - "$ATTEMPTS_FILE" "$LATEST_FILE" "$CONTAINER_FIXES_FILE" "$CONTAINER_FIX_ID" "$NOTE" "$TRIAGED_AT" "$instance_input" "$attempt_input" <<'PY'
import json
import pathlib
import sys

(
    attempts_path_raw,
    latest_path_raw,
    fixes_path_raw,
    container_fix_id,
    note,
    triaged_at,
    instance_input_raw,
    attempt_input_raw,
) = sys.argv[1:]

attempts_path = pathlib.Path(attempts_path_raw)
latest_path = pathlib.Path(latest_path_raw)
fixes_path = pathlib.Path(fixes_path_raw)
instance_input = pathlib.Path(instance_input_raw)
attempt_input = pathlib.Path(attempt_input_raw)


def normalized_lines(path):
    out = []
    if not path.exists():
        return out
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        value = raw_line.strip()
        if not value or value.startswith("#"):
            continue
        out.append(value)
    return out


def dedupe(values):
    out = []
    seen = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


if container_fix_id:
    matches = 0
    for line_number, raw_line in enumerate(fixes_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(
                f"invalid JSON in {fixes_path} at line {line_number}: {exc.msg}"
            ) from exc
        if isinstance(row, dict) and row.get("container_fix_id") == container_fix_id:
            matches += 1
    if matches == 0:
        raise SystemExit(f"container_fix_id not found in {fixes_path}: {container_fix_id}")
    if matches > 1:
        raise SystemExit(f"container_fix_id is duplicated in {fixes_path}: {container_fix_id}")

attempt_rows = []
attempt_index = {}
attempts_for_instance = {}
raw_lines = attempts_path.read_text(encoding="utf-8").splitlines()
for i, raw_line in enumerate(raw_lines):
    line = raw_line.strip()
    if not line:
        attempt_rows.append({"kind": "raw", "raw": raw_line})
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        attempt_rows.append({"kind": "raw", "raw": raw_line})
        continue
    if not isinstance(row, dict):
        attempt_rows.append({"kind": "json", "row": row})
        continue
    attempt_id = row.get("attempt_id")
    instance_id = row.get("instance_id")
    if isinstance(attempt_id, str) and attempt_id:
        attempt_index[attempt_id] = i
    if isinstance(instance_id, str) and instance_id:
        attempts_for_instance.setdefault(instance_id, []).append(i)
    attempt_rows.append({"kind": "json", "row": row})

try:
    latest_payload = json.loads(latest_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    raise SystemExit(f"invalid JSON in {latest_path}: {exc.msg}") from exc

if not isinstance(latest_payload, dict):
    latest_payload = {}

instance_ids = dedupe(normalized_lines(instance_input))
explicit_attempt_ids = dedupe(normalized_lines(attempt_input))

resolved_attempt_ids = []
for instance_id in instance_ids:
    candidate_attempt_id = ""
    latest_entry = latest_payload.get(instance_id)
    if isinstance(latest_entry, dict):
        value = latest_entry.get("attempt_id")
        if isinstance(value, str):
            candidate_attempt_id = value.strip()

    selected_index = None
    if candidate_attempt_id and candidate_attempt_id in attempt_index:
        row_idx = attempt_index[candidate_attempt_id]
        row = attempt_rows[row_idx].get("row")
        if isinstance(row, dict) and row.get("instance_id") == instance_id:
            selected_index = row_idx

    if selected_index is None:
        row_indexes = attempts_for_instance.get(instance_id, [])
        if row_indexes:
            selected_index = row_indexes[-1]

    if selected_index is None:
        raise SystemExit(f"no attempts found for instance_id: {instance_id}")

    row = attempt_rows[selected_index].get("row")
    if not isinstance(row, dict):
        raise SystemExit(f"selected row for instance_id is invalid: {instance_id}")
    attempt_id = row.get("attempt_id")
    if not isinstance(attempt_id, str) or not attempt_id:
        raise SystemExit(f"selected row for instance_id has missing attempt_id: {instance_id}")
    resolved_attempt_ids.append(attempt_id)

selected_attempt_ids = dedupe(explicit_attempt_ids + resolved_attempt_ids)
if not selected_attempt_ids:
    raise SystemExit("no attempts selected for triage after normalization")

selected_rows = []
for attempt_id in selected_attempt_ids:
    row_index = attempt_index.get(attempt_id)
    if row_index is None:
        raise SystemExit(f"attempt_id not found in {attempts_path}: {attempt_id}")
    row = attempt_rows[row_index].get("row")
    if not isinstance(row, dict):
        raise SystemExit(f"selected attempt row is invalid for attempt_id: {attempt_id}")

    evaluation = row.get("evaluation")
    if not isinstance(evaluation, dict):
        evaluation = {}
    evaluation_result = evaluation.get("result")
    if evaluation_result != "eval_error":
        raise SystemExit(
            f"attempt_id {attempt_id} is not eligible for container triage: evaluation.result={evaluation_result!r}"
        )

    classification = row.get("classification")
    if classification not in {"infra_unclassified", "container_porting_defect"}:
        raise SystemExit(
            f"attempt_id {attempt_id} has incompatible classification for triage: {classification!r}"
        )

    selected_rows.append((attempt_id, row_index, row))

updated_instances = set()
for attempt_id, row_index, row in selected_rows:
    row["classification"] = "container_porting_defect"
    if container_fix_id:
        row["container_fix_id"] = container_fix_id
    row["triaged_at"] = triaged_at

    note_tail = "triage classification=container_porting_defect"
    if container_fix_id:
        note_tail += f" container_fix_id={container_fix_id}"
    note_tail += f" note={note}"

    notes = row.get("notes")
    if isinstance(notes, str) and notes.strip():
        row["notes"] = notes + "; " + note_tail
    else:
        row["notes"] = note_tail

    attempt_rows[row_index]["row"] = row
    instance_id = row.get("instance_id")
    if isinstance(instance_id, str) and instance_id:
        updated_instances.add(instance_id)

for instance_id in updated_instances:
    latest_entry = latest_payload.get(instance_id)
    if not isinstance(latest_entry, dict):
        continue
    latest_attempt_id = latest_entry.get("attempt_id")
    if not isinstance(latest_attempt_id, str) or not latest_attempt_id:
        continue
    latest_row_index = attempt_index.get(latest_attempt_id)
    if latest_row_index is None:
        continue
    latest_row = attempt_rows[latest_row_index].get("row")
    if not isinstance(latest_row, dict):
        continue
    if latest_row.get("instance_id") != instance_id:
        continue

    latest_entry["classification"] = latest_row.get("classification")
    if container_fix_id:
        latest_entry["container_fix_id"] = container_fix_id
    evaluation = latest_row.get("evaluation")
    if isinstance(evaluation, dict):
        result = evaluation.get("result")
        if isinstance(result, str):
            latest_entry["evaluation_result"] = result
    latest_entry["triaged_at"] = triaged_at
    latest_payload[instance_id] = latest_entry

updated_lines = []
for payload in attempt_rows:
    if payload.get("kind") == "raw":
        updated_lines.append(payload.get("raw", ""))
    else:
        updated_lines.append(json.dumps(payload.get("row"), separators=(",", ":")))

attempts_path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
latest_path.write_text(json.dumps(latest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

print(f"attempts_file={attempts_path}")
print(f"latest_file={latest_path}")
print(f"selected_attempts={len(selected_attempt_ids)}")
print(f"updated_instances={len(updated_instances)}")
print(f"classification=container_porting_defect")
if container_fix_id:
    print(f"container_fix_id={container_fix_id}")
PY
