#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-select-container-fix-targets.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/phase5-select-container-fix-targets.sh"
  chmod +x "$tmpdir/scripts/phase5-select-container-fix-targets.sh"
  echo "$tmpdir"
}

write_fixture() {
  local campaign_root="$1"
  local targets_file="$campaign_root/targets/unresolved_ids.txt"
  local fixes_file="$campaign_root/state/container_fixes.jsonl"

  mkdir -p "$campaign_root/targets" "$campaign_root/state"
  cat > "$targets_file" <<'EOF'
repo__alpha-1
repo__beta-2
repo__gamma-3
repo__delta-4
EOF

  python3 - "$fixes_file" <<'PY'
import json
import pathlib
import sys

fixes_path = pathlib.Path(sys.argv[1])
rows = [
    {
        "container_fix_id": "fix-001",
        "date": "2026-03-02T00:00:00Z",
        "description": "first fix",
        "files_changed": ["a.txt"],
        "affected_instances": ["repo__gamma-3", "repo__alpha-1", "repo__missing-9"],
    },
    {
        "container_fix_id": "fix-002",
        "date": "2026-03-02T00:10:00Z",
        "description": "second fix",
        "files_changed": ["b.txt"],
        "affected_instances": ["repo__delta-4"],
    },
]
fixes_path.write_text(
    "\n".join(json.dumps(row, separators=(",", ":")) for row in rows) + "\n",
    encoding="utf-8",
)
PY
}

run_case_select_and_missing_id() {
  local tmpdir
  local campaign_root
  local output_path

  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  output_path="$tmpdir/selected_ids.txt"
  write_fixture "$campaign_root"

  (
    cd "$tmpdir"
    ./scripts/phase5-select-container-fix-targets.sh \
      --campaign-root "$campaign_root" \
      --container-fix-id fix-001 \
      --output "$output_path"
  ) > /tmp/phase5-select-container-fix-targets-test.out 2> /tmp/phase5-select-container-fix-targets-test.err

  [[ -f "$output_path" ]] || fail "selector output file should be created"

  python3 - /tmp/phase5-select-container-fix-targets-test.out "$output_path" <<'PY'
import pathlib
import sys

stdout_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])

stdout_ids = [line.strip() for line in stdout_path.read_text(encoding="utf-8").splitlines() if line.strip()]
file_ids = [line.strip() for line in output_path.read_text(encoding="utf-8").splitlines() if line.strip()]
expected = ["repo__alpha-1", "repo__gamma-3"]
assert stdout_ids == expected, stdout_ids
assert file_ids == expected, file_ids
PY

  set +e
  (
    cd "$tmpdir"
    ./scripts/phase5-select-container-fix-targets.sh \
      --campaign-root "$campaign_root" \
      --container-fix-id fix-404
  ) > /tmp/phase5-select-container-fix-targets-test.out 2> /tmp/phase5-select-container-fix-targets-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "missing fix id should fail"
}

run_case_select_and_missing_id

echo "PASS: phase5-select-container-fix-targets"
