#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-triage-container-defect.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/phase5-triage-container-defect.sh"
  chmod +x "$tmpdir/scripts/phase5-triage-container-defect.sh"
  echo "$tmpdir"
}

write_campaign_fixture() {
  local campaign_root="$1"
  local attempts_file="$campaign_root/state/attempts.jsonl"
  local latest_file="$campaign_root/state/instance_latest.json"
  local fixes_file="$campaign_root/state/container_fixes.jsonl"

  mkdir -p "$campaign_root/state"

  python3 - "$attempts_file" "$latest_file" "$fixes_file" <<'PY'
import json
import pathlib
import sys

attempts_path = pathlib.Path(sys.argv[1])
latest_path = pathlib.Path(sys.argv[2])
fixes_path = pathlib.Path(sys.argv[3])

rows = [
    {
        "instance_id": "repo__alpha-1",
        "attempt_id": "repo__alpha-1-attempt-001",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "eval_error"},
        "classification": "infra_unclassified",
        "container_fix_id": None,
        "notes": "fixture alpha",
    },
    {
        "instance_id": "repo__beta-2",
        "attempt_id": "repo__beta-2-attempt-001",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "unresolved"},
        "classification": "agent_failure",
        "container_fix_id": None,
        "notes": "fixture beta",
    },
    {
        "instance_id": "repo__gamma-3",
        "attempt_id": "repo__gamma-3-attempt-001",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "eval_error"},
        "classification": "infra_unclassified",
        "container_fix_id": None,
        "notes": "fixture gamma old",
    },
    {
        "instance_id": "repo__gamma-3",
        "attempt_id": "repo__gamma-3-attempt-002",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "eval_error"},
        "classification": "infra_unclassified",
        "container_fix_id": None,
        "notes": "fixture gamma latest",
    },
    {
        "instance_id": "repo__delta-4",
        "attempt_id": "repo__delta-4-attempt-001",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "eval_error"},
        "classification": "container_porting_defect",
        "container_fix_id": None,
        "notes": "fixture delta already triaged",
    },
]

latest = {
    "repo__alpha-1": {
        "instance_id": "repo__alpha-1",
        "attempt_id": "repo__alpha-1-attempt-001",
        "prediction_status": "success",
        "patch_non_empty": True,
        "evaluation_result": "eval_error",
        "classification": "infra_unclassified",
    },
    "repo__beta-2": {
        "instance_id": "repo__beta-2",
        "attempt_id": "repo__beta-2-attempt-001",
        "prediction_status": "success",
        "patch_non_empty": True,
        "evaluation_result": "unresolved",
        "classification": "agent_failure",
    },
    "repo__gamma-3": {
        "instance_id": "repo__gamma-3",
        "attempt_id": "repo__gamma-3-attempt-002",
        "prediction_status": "success",
        "patch_non_empty": True,
        "evaluation_result": "eval_error",
        "classification": "infra_unclassified",
    },
    "repo__delta-4": {
        "instance_id": "repo__delta-4",
        "attempt_id": "repo__delta-4-attempt-001",
        "prediction_status": "success",
        "patch_non_empty": True,
        "evaluation_result": "eval_error",
        "classification": "container_porting_defect",
    },
}

fixes = [
    {
        "container_fix_id": "fix-001",
        "date": "2026-03-02T02:00:00Z",
        "description": "ARM64 container startup fix",
        "files_changed": ["docker_build.py"],
        "affected_instances": ["repo__alpha-1", "repo__gamma-3", "repo__delta-4"],
    }
]

attempts_path.write_text(
    "\n".join(json.dumps(row, separators=(",", ":")) for row in rows) + "\n",
    encoding="utf-8",
)
latest_path.write_text(json.dumps(latest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
fixes_path.write_text(
    "\n".join(json.dumps(row, separators=(",", ":")) for row in fixes) + "\n",
    encoding="utf-8",
)
PY
}

run_case_promote_selected_attempts() {
  local tmpdir
  local campaign_root
  local instance_ids_file
  local attempts_file
  local latest_file

  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  instance_ids_file="$tmpdir/triage-instances.txt"
  attempts_file="$campaign_root/state/attempts.jsonl"
  latest_file="$campaign_root/state/instance_latest.json"

  write_campaign_fixture "$campaign_root"
  cat > "$instance_ids_file" <<'EOF'
# comment
repo__gamma-3
repo__gamma-3
EOF

  (
    cd "$tmpdir"
    ./scripts/phase5-triage-container-defect.sh \
      --campaign-root "$campaign_root" \
      --note "docker buildx missing on arm64" \
      --container-fix-id fix-001 \
      --instance-id repo__alpha-1 \
      --instance-ids-file "$instance_ids_file" \
      --attempt-id repo__delta-4-attempt-001
  ) > /tmp/phase5-triage-container-defect-test.out 2> /tmp/phase5-triage-container-defect-test.err

  rg -F -q "selected_attempts=3" /tmp/phase5-triage-container-defect-test.out || fail "stdout missing selected_attempts"
  rg -F -q "container_fix_id=fix-001" /tmp/phase5-triage-container-defect-test.out || fail "stdout missing container_fix_id"

  python3 - "$attempts_file" "$latest_file" <<'PY'
import json
import pathlib
import sys

attempts_path = pathlib.Path(sys.argv[1])
latest_path = pathlib.Path(sys.argv[2])

rows = {}
for raw_line in attempts_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line:
        continue
    row = json.loads(line)
    rows[row["attempt_id"]] = row

alpha = rows["repo__alpha-1-attempt-001"]
assert alpha["classification"] == "container_porting_defect"
assert alpha["container_fix_id"] == "fix-001"
assert "triage classification=container_porting_defect" in alpha["notes"]
assert "note=docker buildx missing on arm64" in alpha["notes"]
assert alpha.get("triaged_at")

beta = rows["repo__beta-2-attempt-001"]
assert beta["classification"] == "agent_failure"
assert beta["container_fix_id"] is None

gamma_old = rows["repo__gamma-3-attempt-001"]
assert gamma_old["classification"] == "infra_unclassified"
assert gamma_old["container_fix_id"] is None

gamma_latest = rows["repo__gamma-3-attempt-002"]
assert gamma_latest["classification"] == "container_porting_defect"
assert gamma_latest["container_fix_id"] == "fix-001"

delta = rows["repo__delta-4-attempt-001"]
assert delta["classification"] == "container_porting_defect"
assert delta["container_fix_id"] == "fix-001"

latest = json.loads(latest_path.read_text(encoding="utf-8"))
assert latest["repo__alpha-1"]["classification"] == "container_porting_defect"
assert latest["repo__alpha-1"]["container_fix_id"] == "fix-001"
assert latest["repo__gamma-3"]["classification"] == "container_porting_defect"
assert latest["repo__gamma-3"]["container_fix_id"] == "fix-001"
assert latest["repo__delta-4"]["classification"] == "container_porting_defect"
assert latest["repo__delta-4"]["container_fix_id"] == "fix-001"
assert latest["repo__beta-2"]["classification"] == "agent_failure"
PY
}

run_case_reject_non_eval_error_attempt() {
  local tmpdir
  local campaign_root

  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-b"

  write_campaign_fixture "$campaign_root"

  set +e
  (
    cd "$tmpdir"
    ./scripts/phase5-triage-container-defect.sh \
      --campaign-root "$campaign_root" \
      --note "should fail for agent failure" \
      --instance-id repo__beta-2
  ) > /tmp/phase5-triage-container-defect-test.out 2> /tmp/phase5-triage-container-defect-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "non eval_error attempt should fail triage"
  rg -F -q "not eligible for container triage" /tmp/phase5-triage-container-defect-test.err || fail "stderr missing eligibility error"
}

run_case_promote_selected_attempts
run_case_reject_non_eval_error_attempt

echo "PASS: phase5-triage-container-defect"
