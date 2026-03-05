#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CAMPAIGN_ROOT=""
CONTAINER_FIX_ID=""
FIX_DATE=""
DESCRIPTION=""
CONTAINER_FIXES_FILE=""
declare -a FILES_CHANGED=()
declare -a AFFECTED_INSTANCES=()
declare -a AFFECTED_INSTANCE_FILES=()

usage() {
  cat <<USAGE
Usage: scripts/phase5-record-container-fix.sh --campaign-root <path> --container-fix-id <id> --description <text> [options]

Required:
  --campaign-root <path>      Campaign run root containing state/
  --container-fix-id <id>     Unique fix identifier to append
  --description <text>        Short fix description
  --affected-instance <id>    Affected instance ID (repeatable, at least one required across all sources)

Options:
  --date <utc-ts>             Fix timestamp (default: current UTC, RFC3339 Z)
  --file-changed <path>       Changed file path (repeatable)
  --affected-instances-file <path>
                              File containing affected instance IDs (one per line; supports # comments)
  --container-fixes-file <path>
                              Override fix log path (default: <campaign-root>/state/container_fixes.jsonl)
  -h, --help                  Show this help message

Behavior:
  - Appends one JSON row to state/container_fixes.jsonl
  - Enforces unique container_fix_id within that file
  - Stores deterministic deduped affected_instances and files_changed arrays
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
    --container-fix-id)
      [[ $# -ge 2 ]] || { error "--container-fix-id requires a value"; exit 2; }
      CONTAINER_FIX_ID="$2"
      shift 2
      ;;
    --description)
      [[ $# -ge 2 ]] || { error "--description requires a value"; exit 2; }
      DESCRIPTION="$2"
      shift 2
      ;;
    --date)
      [[ $# -ge 2 ]] || { error "--date requires a value"; exit 2; }
      FIX_DATE="$2"
      shift 2
      ;;
    --file-changed)
      [[ $# -ge 2 ]] || { error "--file-changed requires a value"; exit 2; }
      FILES_CHANGED+=("$2")
      shift 2
      ;;
    --affected-instance)
      [[ $# -ge 2 ]] || { error "--affected-instance requires a value"; exit 2; }
      AFFECTED_INSTANCES+=("$2")
      shift 2
      ;;
    --affected-instances-file)
      [[ $# -ge 2 ]] || { error "--affected-instances-file requires a value"; exit 2; }
      AFFECTED_INSTANCE_FILES+=("$2")
      shift 2
      ;;
    --container-fixes-file)
      [[ $# -ge 2 ]] || { error "--container-fixes-file requires a value"; exit 2; }
      CONTAINER_FIXES_FILE="$2"
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

if [[ -z "$DESCRIPTION" ]]; then
  error "--description is required"
  usage >&2
  exit 2
fi

if [[ "${#AFFECTED_INSTANCES[@]}" -eq 0 && "${#AFFECTED_INSTANCE_FILES[@]}" -eq 0 ]]; then
  error "at least one --affected-instance or --affected-instances-file is required"
  usage >&2
  exit 2
fi

CAMPAIGN_ROOT="$(absolute_path_from_pwd "$CAMPAIGN_ROOT")"
if [[ -z "$FIX_DATE" ]]; then
  FIX_DATE="$(timestamp_utc)"
fi

if [[ -z "$CONTAINER_FIXES_FILE" ]]; then
  CONTAINER_FIXES_FILE="$CAMPAIGN_ROOT/state/container_fixes.jsonl"
else
  CONTAINER_FIXES_FILE="$(absolute_path_from_pwd "$CONTAINER_FIXES_FILE")"
fi

files_input="$(mktemp)"
affected_input="$(mktemp)"
trap 'rm -f "$files_input" "$affected_input"' EXIT

for path in "${FILES_CHANGED[@]}"; do
  printf '%s\n' "$path" >> "$files_input"
done

for instance_id in "${AFFECTED_INSTANCES[@]}"; do
  printf '%s\n' "$instance_id" >> "$affected_input"
done

if [[ "${#AFFECTED_INSTANCE_FILES[@]}" -gt 0 ]]; then
  for source_path in "${AFFECTED_INSTANCE_FILES[@]}"; do
    source_abs="$(absolute_path_from_pwd "$source_path")"
    if [[ ! -f "$source_abs" ]]; then
      error "affected instances file not found: $source_abs"
      exit 1
    fi
    cat "$source_abs" >> "$affected_input"
    printf '\n' >> "$affected_input"
  done
fi

mkdir -p "$(dirname "$CONTAINER_FIXES_FILE")"
touch "$CONTAINER_FIXES_FILE"

python3 - "$CONTAINER_FIXES_FILE" "$CONTAINER_FIX_ID" "$FIX_DATE" "$DESCRIPTION" "$files_input" "$affected_input" <<'PY'
import json
import pathlib
import sys

(
    container_fixes_path_raw,
    container_fix_id,
    fix_date,
    description,
    files_input_raw,
    affected_input_raw,
) = sys.argv[1:]

container_fixes_path = pathlib.Path(container_fixes_path_raw)
files_input = pathlib.Path(files_input_raw)
affected_input = pathlib.Path(affected_input_raw)


def normalized_lines(path):
    values = []
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        value = raw_line.strip()
        if not value or value.startswith("#"):
            continue
        values.append(value)
    return values


def dedupe(values):
    out = []
    seen = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        out.append(value)
    return out


files_changed = dedupe(normalized_lines(files_input))
affected_instances = sorted(dedupe(normalized_lines(affected_input)))

if not affected_instances:
    raise SystemExit("no affected instance IDs were provided after normalization")

for line_number, raw_line in enumerate(container_fixes_path.read_text(encoding="utf-8").splitlines(), start=1):
    line = raw_line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(row, dict) and row.get("container_fix_id") == container_fix_id:
        raise SystemExit(
            f"container_fix_id already exists in {container_fixes_path} at line {line_number}: {container_fix_id}"
        )

record = {
    "container_fix_id": container_fix_id,
    "date": fix_date,
    "description": description,
    "files_changed": files_changed,
    "affected_instances": affected_instances,
}

with container_fixes_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":")) + "\n")

print(f"container_fixes_file={container_fixes_path}")
print(f"container_fix_id={container_fix_id}")
print(f"affected_instances={len(affected_instances)}")
print(f"files_changed={len(files_changed)}")
PY
