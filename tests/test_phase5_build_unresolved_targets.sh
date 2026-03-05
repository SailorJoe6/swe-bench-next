#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-build-unresolved-targets.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/phase5-build-unresolved-targets.sh"
  chmod +x "$tmpdir/scripts/phase5-build-unresolved-targets.sh"
  echo "$tmpdir"
}

run_case_success_sorted_and_deduped() {
  local tmpdir
  local summary_path
  local campaign_root
  local target_file
  tmpdir="$(make_isolated_root)"
  summary_path="$tmpdir/results/phase3/full-run.eval-batch.json"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  target_file="$campaign_root/targets/unresolved_ids.txt"

  mkdir -p "$(dirname "$summary_path")"
  cat > "$summary_path" <<'EOF'
{
  "total_instances": 300,
  "resolved_instances": 168,
  "unresolved_ids": [
    "repo__zeta-9",
    "repo__alpha-1",
    "repo__beta-2",
    "repo__alpha-1",
    "   repo__beta-2   ",
    "",
    42
  ]
}
EOF

  set +e
  "$tmpdir/scripts/phase5-build-unresolved-targets.sh" \
    --phase3-summary "$summary_path" \
    --campaign-root "$campaign_root" > /tmp/phase5-build-targets-test.out 2> /tmp/phase5-build-targets-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "target builder should succeed on valid summary"
  [[ -f "$target_file" ]] || fail "target file was not created"
  [[ -d "$campaign_root/state" ]] || fail "state directory was not created"
  [[ -d "$campaign_root/reports" ]] || fail "reports directory was not created"

  python3 - "$target_file" <<'PY'
import pathlib
import sys

target_file = pathlib.Path(sys.argv[1])
lines = [line.strip() for line in target_file.read_text(encoding="utf-8").splitlines() if line.strip()]
assert lines == ["repo__alpha-1", "repo__beta-2", "repo__zeta-9"], lines
PY

  rg -F -q "campaign_root=$campaign_root" /tmp/phase5-build-targets-test.out || fail "missing campaign_root output"
  rg -F -q "target_count=3" /tmp/phase5-build-targets-test.out || fail "missing target_count output"
}

run_case_missing_summary_fails() {
  local tmpdir
  tmpdir="$(make_isolated_root)"

  set +e
  "$tmpdir/scripts/phase5-build-unresolved-targets.sh" \
    --phase3-summary "$tmpdir/missing-summary.json" > /tmp/phase5-build-targets-test.out 2> /tmp/phase5-build-targets-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "missing summary should fail"
  rg -F -q "Phase 3 summary file not found" /tmp/phase5-build-targets-test.err || fail "missing summary error text not found"
}

run_case_reuse_existing_and_force_overwrite() {
  local tmpdir
  local summary_path
  local campaign_root
  local target_file
  tmpdir="$(make_isolated_root)"
  summary_path="$tmpdir/results/phase3/full-run.eval-batch.json"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-b"
  target_file="$campaign_root/targets/unresolved_ids.txt"

  mkdir -p "$(dirname "$summary_path")"
  cat > "$summary_path" <<'EOF'
{
  "unresolved_ids": ["repo__first-1", "repo__second-2"]
}
EOF

  "$tmpdir/scripts/phase5-build-unresolved-targets.sh" \
    --phase3-summary "$summary_path" \
    --campaign-root "$campaign_root" > /tmp/phase5-build-targets-test.out 2> /tmp/phase5-build-targets-test.err

  cat > "$summary_path" <<'EOF'
{
  "unresolved_ids": ["repo__replacement-7"]
}
EOF

  set +e
  "$tmpdir/scripts/phase5-build-unresolved-targets.sh" \
    --phase3-summary "$summary_path" \
    --campaign-root "$campaign_root" > /tmp/phase5-build-targets-test.out 2> /tmp/phase5-build-targets-test.err
  local status_without_force=$?
  set -e

  assert_eq "0" "$status_without_force" "second write without --force should reuse existing target file"
  rg -F -q "reused_existing=1" /tmp/phase5-build-targets-test.out || fail "missing reused_existing marker in output"

  python3 - "$target_file" <<'PY'
import pathlib
import sys

target_file = pathlib.Path(sys.argv[1])
lines = [line.strip() for line in target_file.read_text(encoding="utf-8").splitlines() if line.strip()]
assert lines == ["repo__first-1", "repo__second-2"], lines
PY

  "$tmpdir/scripts/phase5-build-unresolved-targets.sh" \
    --phase3-summary "$summary_path" \
    --campaign-root "$campaign_root" \
    --force > /tmp/phase5-build-targets-test.out 2> /tmp/phase5-build-targets-test.err

  python3 - "$target_file" <<'PY'
import pathlib
import sys

target_file = pathlib.Path(sys.argv[1])
lines = [line.strip() for line in target_file.read_text(encoding="utf-8").splitlines() if line.strip()]
assert lines == ["repo__replacement-7"], lines
PY
}

run_case_default_campaign_root() {
  local tmpdir
  local summary_path
  local default_campaign_root
  local target_file
  tmpdir="$(make_isolated_root)"
  summary_path="$tmpdir/results/phase3/full-run.eval-batch.json"
  default_campaign_root="$tmpdir/results/phase5/unresolved-campaign/current"
  target_file="$default_campaign_root/targets/unresolved_ids.txt"

  mkdir -p "$(dirname "$summary_path")"
  cat > "$summary_path" <<'EOF'
{
  "unresolved_ids": ["repo__single-1"]
}
EOF

  "$tmpdir/scripts/phase5-build-unresolved-targets.sh" \
    --phase3-summary "$summary_path" > /tmp/phase5-build-targets-test.out 2> /tmp/phase5-build-targets-test.err

  [[ -f "$target_file" ]] || fail "default campaign root target file was not created"
  rg -F -q "campaign_root=$default_campaign_root" /tmp/phase5-build-targets-test.out || fail "default campaign_root output mismatch"
}

run_case_success_sorted_and_deduped
run_case_missing_summary_fails
run_case_reuse_existing_and_force_overwrite
run_case_default_campaign_root

echo "PASS: phase5-build-unresolved-targets"
