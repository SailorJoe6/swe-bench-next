#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-record-container-fix.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/phase5-record-container-fix.sh"
  chmod +x "$tmpdir/scripts/phase5-record-container-fix.sh"
  echo "$tmpdir"
}

run_case_append_and_duplicate_guard() {
  local tmpdir
  local campaign_root
  local fixes_file
  local affected_file

  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  fixes_file="$campaign_root/state/container_fixes.jsonl"
  affected_file="$tmpdir/affected.txt"
  mkdir -p "$campaign_root/state"

  cat > "$affected_file" <<'EOF'
repo__gamma-3
repo__alpha-1
repo__gamma-3
EOF

  (
    cd "$tmpdir"
    ./scripts/phase5-record-container-fix.sh \
      --campaign-root "$campaign_root" \
      --container-fix-id fix-001 \
      --date 2026-03-02T03:00:00Z \
      --description "Fix ARM64 container startup command" \
      --file-changed swebench/harness/docker_build.py \
      --file-changed swebench/harness/docker_build.py \
      --file-changed sweagent/environment/swe_env.py \
      --affected-instance repo__beta-2 \
      --affected-instances-file "$affected_file"
  ) > /tmp/phase5-record-container-fix-test.out 2> /tmp/phase5-record-container-fix-test.err

  [[ -f "$fixes_file" ]] || fail "container_fixes.jsonl should be created"
  rg -F -q "container_fix_id=fix-001" /tmp/phase5-record-container-fix-test.out || fail "stdout missing fix id"

  python3 - "$fixes_file" <<'PY'
import json
import pathlib
import sys

fixes_path = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in fixes_path.read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(rows) == 1, rows
row = rows[0]
assert row["container_fix_id"] == "fix-001"
assert row["date"] == "2026-03-02T03:00:00Z"
assert row["description"] == "Fix ARM64 container startup command"
assert row["files_changed"] == [
    "swebench/harness/docker_build.py",
    "sweagent/environment/swe_env.py",
], row["files_changed"]
assert row["affected_instances"] == [
    "repo__alpha-1",
    "repo__beta-2",
    "repo__gamma-3",
], row["affected_instances"]
PY

  set +e
  (
    cd "$tmpdir"
    ./scripts/phase5-record-container-fix.sh \
      --campaign-root "$campaign_root" \
      --container-fix-id fix-001 \
      --description "duplicate id should fail" \
      --affected-instance repo__alpha-1
  ) > /tmp/phase5-record-container-fix-test.out 2> /tmp/phase5-record-container-fix-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "duplicate fix id should fail"
}

run_case_append_and_duplicate_guard

echo "PASS: phase5-record-container-fix"
