#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase5-summarize-campaign.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/phase5-summarize-campaign.sh"
  chmod +x "$tmpdir/scripts/phase5-summarize-campaign.sh"
  echo "$tmpdir"
}

write_campaign_fixture() {
  local campaign_root="$1"
  local targets_file="$campaign_root/targets/unresolved_ids.txt"
  local attempts_file="$campaign_root/state/attempts.jsonl"
  local latest_file="$campaign_root/state/instance_latest.json"

  mkdir -p "$campaign_root/targets" "$campaign_root/state" "$campaign_root/reports"
  cat > "$targets_file" <<'EOF'
repo__alpha-1
repo__beta-2
repo__gamma-3
repo__delta-4
repo__epsilon-5
EOF

  python3 - "$attempts_file" "$latest_file" <<'PY'
import json
import pathlib
import sys

attempts_path = pathlib.Path(sys.argv[1])
latest_path = pathlib.Path(sys.argv[2])

rows = [
    {
        "instance_id": "repo__alpha-1",
        "attempt_id": "repo__alpha-1-attempt-001",
        "attempt_finished_at": "2026-03-02T00:01:00Z",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "resolved"},
        "classification": "resolved",
        "container_fix_id": None,
    },
    {
        "instance_id": "repo__beta-2",
        "attempt_id": "repo__beta-2-attempt-001",
        "attempt_finished_at": "2026-03-02T00:02:00Z",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "unresolved"},
        "classification": "agent_failure",
        "container_fix_id": None,
    },
    {
        "instance_id": "repo__beta-2",
        "attempt_id": "repo__beta-2-attempt-002",
        "attempt_finished_at": "2026-03-02T00:03:00Z",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "resolved"},
        "classification": "resolved",
        "container_fix_id": None,
    },
    {
        "instance_id": "repo__gamma-3",
        "attempt_id": "repo__gamma-3-attempt-001",
        "attempt_finished_at": "2026-03-02T00:04:00Z",
        "prediction": {"status": "success", "patch_non_empty": True},
        "evaluation": {"executed": True, "result": "eval_error"},
        "classification": "infra_unclassified",
        "container_fix_id": None,
    },
    {
        "instance_id": "repo__delta-4",
        "attempt_id": "repo__delta-4-attempt-001",
        "attempt_finished_at": "2026-03-02T00:05:00Z",
        "prediction": {"status": "failed", "patch_non_empty": False},
        "evaluation": {"executed": False, "result": "not_run"},
        "classification": "infra_unclassified",
        "container_fix_id": None,
    },
]

latest_payload = {
    "repo__alpha-1": {"attempt_id": "repo__alpha-1-attempt-001"},
    "repo__beta-2": {"attempt_id": "repo__beta-2-attempt-001"},
    "repo__gamma-3": {"attempt_id": "repo__gamma-3-attempt-001"},
    "repo__delta-4": {"attempt_id": "repo__delta-4-attempt-001"},
}

attempts_path.write_text(
    "\n".join(json.dumps(row, separators=(",", ":")) for row in rows) + "\n",
    encoding="utf-8",
)
latest_path.write_text(json.dumps(latest_payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

run_case_summary_counts_and_latest_selection() {
  local tmpdir
  local campaign_root
  local summary_path
  tmpdir="$(make_isolated_root)"
  campaign_root="$tmpdir/results/phase5/unresolved-campaign/campaign-a"
  summary_path="$campaign_root/reports/final_summary.json"

  write_campaign_fixture "$campaign_root"

  set +e
  (
    cd "$tmpdir"
    ./scripts/phase5-summarize-campaign.sh --campaign-root "$campaign_root"
  ) > /tmp/phase5-summarize-campaign-test.out 2> /tmp/phase5-summarize-campaign-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "summarizer should succeed on valid campaign state"
  [[ -f "$summary_path" ]] || fail "summary output was not written"

  rg -F -q "resolved_by_phase5=1" /tmp/phase5-summarize-campaign-test.out || fail "stdout missing resolved count"
  rg -F -q "unresolved_agent_failure=1" /tmp/phase5-summarize-campaign-test.out || fail "stdout missing agent count"
  rg -F -q "unresolved_infra_or_container=2" /tmp/phase5-summarize-campaign-test.out || fail "stdout missing infra/container count"
  rg -F -q "not_attempted=1" /tmp/phase5-summarize-campaign-test.out || fail "stdout missing not-attempted count"

  python3 - "$summary_path" "$campaign_root" <<'PY'
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
campaign_root = pathlib.Path(sys.argv[2])
payload = json.loads(summary_path.read_text(encoding="utf-8"))

counts = payload["counts"]
assert counts["total_targets"] == 5, counts
assert counts["attempted_instances"] == 4, counts
assert counts["resolved_by_phase5"] == 1, counts
assert counts["unresolved_agent_failure"] == 1, counts
assert counts["unresolved_infra_or_container"] == 2, counts
assert counts["not_attempted"] == 1, counts

report = payload["classification_report"]
assert report["resolved_by_phase5"] == ["repo__alpha-1"], report
assert report["unresolved_agent_failure"] == ["repo__beta-2"], report
assert report["unresolved_infra_or_container"] == ["repo__gamma-3", "repo__delta-4"], report
assert report["not_attempted"] == ["repo__epsilon-5"], report

instances = {row["instance_id"]: row for row in payload["instances"]}
assert instances["repo__alpha-1"]["summary_bucket"] == "resolved_by_phase5"
assert instances["repo__beta-2"]["summary_bucket"] == "unresolved_agent_failure"
assert instances["repo__beta-2"]["attempt_id"] == "repo__beta-2-attempt-001"
assert instances["repo__gamma-3"]["summary_bucket"] == "unresolved_infra_or_container"
assert instances["repo__delta-4"]["summary_bucket"] == "unresolved_infra_or_container"
assert instances["repo__epsilon-5"]["summary_bucket"] == "not_attempted"

assert pathlib.Path(payload["campaign_root"]) == campaign_root
assert pathlib.Path(payload["attempts_file"]) == campaign_root / "state" / "attempts.jsonl"
assert pathlib.Path(payload["instance_latest_file"]) == campaign_root / "state" / "instance_latest.json"
PY
}

run_case_summary_counts_and_latest_selection

echo "PASS: phase5-summarize-campaign"
