#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_PHASE3_SUMMARY="$REPO_ROOT/results/phase3/full-run.eval-batch.json"
CAMPAIGN_ROOT_PARENT="$REPO_ROOT/results/phase5/unresolved-campaign"
DEFAULT_CAMPAIGN_ROOT="$CAMPAIGN_ROOT_PARENT/current"

PHASE3_SUMMARY="$DEFAULT_PHASE3_SUMMARY"
CAMPAIGN_ROOT=""
FORCE=0

usage() {
  cat <<USAGE
Usage: scripts/phase5-build-unresolved-targets.sh [options]

Options:
  --phase3-summary <path>  Path to Phase 3 eval summary JSON
                           (default: $DEFAULT_PHASE3_SUMMARY)
  --campaign-root <path>   Campaign run root to write targets into
                           (default: $DEFAULT_CAMPAIGN_ROOT)
  --force                  Overwrite existing targets/unresolved_ids.txt if present
  -h, --help               Show this help message

Output:
  <campaign_root>/targets/unresolved_ids.txt
USAGE
}

error() {
  echo "Error: $*" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase3-summary)
      [[ $# -ge 2 ]] || { error "--phase3-summary requires a value"; exit 2; }
      PHASE3_SUMMARY="$2"
      shift 2
      ;;
    --campaign-root)
      [[ $# -ge 2 ]] || { error "--campaign-root requires a value"; exit 2; }
      CAMPAIGN_ROOT="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
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

if [[ ! -f "$PHASE3_SUMMARY" ]]; then
  error "Phase 3 summary file not found: $PHASE3_SUMMARY"
  exit 1
fi

if [[ -z "$CAMPAIGN_ROOT" ]]; then
  CAMPAIGN_ROOT="$DEFAULT_CAMPAIGN_ROOT"
fi

TARGET_DIR="$CAMPAIGN_ROOT/targets"
STATE_DIR="$CAMPAIGN_ROOT/state"
REPORT_DIR="$CAMPAIGN_ROOT/reports"
TARGET_FILE="$TARGET_DIR/unresolved_ids.txt"

mkdir -p "$TARGET_DIR" "$STATE_DIR" "$REPORT_DIR"

if [[ -e "$TARGET_FILE" && "$FORCE" -ne 1 ]]; then
  TARGET_COUNT="$(
    python3 - "$TARGET_FILE" <<'PY'
import pathlib
import sys

target_path = pathlib.Path(sys.argv[1])
lines = [line.strip() for line in target_path.read_text(encoding="utf-8").splitlines()]
ids = sorted({line for line in lines if line and not line.startswith("#")})
if not ids:
    raise SystemExit(f"existing target file is empty: {target_path}")
print(len(ids))
PY
  )"

  printf 'campaign_root=%s\nphase3_summary=%s\ntarget_file=%s\ntarget_count=%s\nreused_existing=1\n' \
    "$CAMPAIGN_ROOT" "$PHASE3_SUMMARY" "$TARGET_FILE" "$TARGET_COUNT"
  exit 0
fi

TARGET_COUNT="$(
  python3 - "$PHASE3_SUMMARY" "$TARGET_FILE" <<'PY'
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
target_path = pathlib.Path(sys.argv[2])

try:
    payload = json.loads(summary_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    raise SystemExit(f"invalid JSON in {summary_path}: {exc.msg}") from exc

unresolved = payload.get("unresolved_ids")
if not isinstance(unresolved, list):
    raise SystemExit(f"{summary_path} must contain unresolved_ids as an array")

ids = sorted({item.strip() for item in unresolved if isinstance(item, str) and item.strip()})
if not ids:
    raise SystemExit(f"{summary_path} has no non-empty unresolved_ids")

target_path.write_text("\n".join(ids) + "\n", encoding="utf-8")
print(len(ids))
PY
)"

printf 'campaign_root=%s\nphase3_summary=%s\ntarget_file=%s\ntarget_count=%s\n' \
  "$CAMPAIGN_ROOT" "$PHASE3_SUMMARY" "$TARGET_FILE" "$TARGET_COUNT"
printf 'reused_existing=0\n'
