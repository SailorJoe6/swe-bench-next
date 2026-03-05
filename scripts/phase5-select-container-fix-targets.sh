#!/usr/bin/env bash
set -euo pipefail

CAMPAIGN_ROOT=""
CONTAINER_FIX_ID=""
CONTAINER_FIXES_FILE=""
TARGETS_FILE=""
OUTPUT_PATH=""

usage() {
  cat <<USAGE
Usage: scripts/phase5-select-container-fix-targets.sh --campaign-root <path> --container-fix-id <id> [options]

Required:
  --campaign-root <path>      Campaign run root containing targets/state
  --container-fix-id <id>     Container fix identifier to select rerun IDs for

Options:
  --container-fixes-file <path>
                              Fix log path (default: <campaign-root>/state/container_fixes.jsonl)
  --targets-file <path>       Campaign target file used for deterministic filtering/order
                              (default: <campaign-root>/targets/unresolved_ids.txt)
  --output <path>             Write selected IDs to file
  -h, --help                  Show this help message

Behavior:
  - Reads one fix record from state/container_fixes.jsonl by exact container_fix_id
  - Selects rerun IDs as intersection(affected_instances, campaign targets)
  - Emits selected IDs to stdout, one per line, in deterministic campaign target order
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

if [[ -z "$CONTAINER_FIX_ID" ]]; then
  error "--container-fix-id is required"
  usage >&2
  exit 2
fi

CAMPAIGN_ROOT="$(absolute_path_from_pwd "$CAMPAIGN_ROOT")"

if [[ -z "$CONTAINER_FIXES_FILE" ]]; then
  CONTAINER_FIXES_FILE="$CAMPAIGN_ROOT/state/container_fixes.jsonl"
else
  CONTAINER_FIXES_FILE="$(absolute_path_from_pwd "$CONTAINER_FIXES_FILE")"
fi

if [[ -z "$TARGETS_FILE" ]]; then
  TARGETS_FILE="$CAMPAIGN_ROOT/targets/unresolved_ids.txt"
else
  TARGETS_FILE="$(absolute_path_from_pwd "$TARGETS_FILE")"
fi

if [[ ! -f "$CONTAINER_FIXES_FILE" ]]; then
  error "container fixes file not found: $CONTAINER_FIXES_FILE"
  exit 1
fi

if [[ ! -f "$TARGETS_FILE" ]]; then
  error "targets file not found: $TARGETS_FILE"
  exit 1
fi

if [[ -n "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$(absolute_path_from_pwd "$OUTPUT_PATH")"
  mkdir -p "$(dirname "$OUTPUT_PATH")"
fi

python3 - "$CONTAINER_FIXES_FILE" "$TARGETS_FILE" "$CONTAINER_FIX_ID" "$OUTPUT_PATH" <<'PY'
import json
import pathlib
import sys

container_fixes_path = pathlib.Path(sys.argv[1])
targets_path = pathlib.Path(sys.argv[2])
container_fix_id = sys.argv[3]
output_path_raw = sys.argv[4]
output_path = pathlib.Path(output_path_raw) if output_path_raw else None


def normalized_target_list(path):
    out = []
    seen = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        value = raw_line.strip()
        if not value or value.startswith("#"):
            continue
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


matching_records = []
for line_number, raw_line in enumerate(container_fixes_path.read_text(encoding="utf-8").splitlines(), start=1):
    line = raw_line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"invalid JSON in {container_fixes_path} at line {line_number}: {exc.msg}"
        ) from exc
    if not isinstance(row, dict):
        continue
    if row.get("container_fix_id") == container_fix_id:
        matching_records.append(row)

if not matching_records:
    raise SystemExit(f"container_fix_id not found: {container_fix_id}")

if len(matching_records) > 1:
    raise SystemExit(f"container_fix_id is duplicated in {container_fixes_path}: {container_fix_id}")

record = matching_records[0]
affected_instances = record.get("affected_instances")
if not isinstance(affected_instances, list):
    affected_instances = []

affected_set = {value.strip() for value in affected_instances if isinstance(value, str) and value.strip()}
target_ids = normalized_target_list(targets_path)
selected_ids = [instance_id for instance_id in target_ids if instance_id in affected_set]

if output_path is not None:
    output_path.write_text("\n".join(selected_ids) + ("\n" if selected_ids else ""), encoding="utf-8")

for instance_id in selected_ids:
    print(instance_id)
PY
