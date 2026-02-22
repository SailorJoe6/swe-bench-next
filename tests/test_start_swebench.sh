#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/start-swebench.sh"

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

make_fake_codex_bin() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$tmpdir/codex"
  echo "$tmpdir"
}

make_isolated_runner_root() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/scripts"
  cp "$SCRIPT" "$tmpdir/scripts/start-swebench.sh"
  chmod +x "$tmpdir/scripts/start-swebench.sh"
  echo "$tmpdir"
}

write_required_prompts() {
  local root="$1"
  mkdir -p "$root/ralph/prompts"
  cat > "$root/ralph/prompts/plan.md" <<'EOF'
plan prompt
EOF
  cat > "$root/ralph/prompts/execute.md" <<'EOF'
execute prompt
EOF
  cat > "$root/ralph/prompts/handoff.md" <<'EOF'
handoff prompt
EOF
}

run_case_missing_required_args() {
  set +e
  "$SCRIPT" > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e
  assert_eq "2" "$status" "missing required args should exit 2"
  rg -q -- "--instance-id is required" /tmp/start-swebench-test.err || fail "missing args error text not found"
}

run_case_invalid_max_loops() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  set +e
  "$SCRIPT" --instance-id test.id --output-dir "$tmpdir/out" --max-loops abc > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "2" "$status" "invalid max loops should exit 2"
  rg -q -- "--max-loops must be a positive integer" /tmp/start-swebench-test.err || fail "invalid max-loops error text not found"
}

run_case_default_manifest_and_artifacts() {
  local tmpdir
  local codex_bin
  local isolated_script
  tmpdir="$(make_isolated_runner_root)"
  codex_bin="$(make_fake_codex_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  write_required_prompts "$tmpdir"

  set +e
  PATH="$codex_bin:$PATH" "$isolated_script" --instance-id repo__issue-1 --output-dir "$tmpdir/out" > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "20" "$status" "phase1 skeleton should currently return 20 for incomplete"

  [[ -f "$tmpdir/out/repo__issue-1.patch" ]] || fail "patch file missing"
  [[ -f "$tmpdir/out/repo__issue-1.pred" ]] || fail "pred file missing"
  [[ -f "$tmpdir/out/repo__issue-1.status.json" ]] || fail "status file missing"
  [[ -f "$tmpdir/out/run_manifest.json" ]] || fail "manifest file missing at default manifest dir"
  [[ -f "$tmpdir/out/logs/codex_command.txt" ]] || fail "codex command lock file missing"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

pred = json.loads((out / "repo__issue-1.pred").read_text(encoding="utf-8"))
assert pred["model_name_or_path"] == "qwen3-coder-next-FP8,codex,ralph"
assert pred["instance_id"] == "repo__issue-1"
assert pred["model_patch"] == ""

status = json.loads((out / "repo__issue-1.status.json").read_text(encoding="utf-8"))
assert status["instance_id"] == "repo__issue-1"
assert status["status"] == "incomplete"
assert status["failure_reason_code"] == "incomplete"

manifest = json.loads((out / "run_manifest.json").read_text(encoding="utf-8"))
assert manifest["dataset"]["name"] == "SWE-bench/SWE-bench_Multilingual"
assert manifest["codex"]["profile"] == "local"
inst = manifest["instances"]["repo__issue-1"]
assert inst["status"] == "incomplete"
assert inst["failure_reason_code"] == "incomplete"
assert manifest["counts"]["total"] == 1
assert manifest["counts"]["incomplete"] == 1
assert manifest["last_invocation"]["args"]["manifest_dir"] == str(out)
PY
}

run_case_missing_runtime_prompts() {
  local tmpdir
  local codex_bin
  local isolated_script
  tmpdir="$(make_isolated_runner_root)"
  codex_bin="$(make_fake_codex_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"

  set +e
  PATH="$codex_bin:$PATH" "$isolated_script" --instance-id repo__issue-2 --output-dir "$tmpdir/out" > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "missing runtime prompts should fail invocation"
  rg -F -q -- "Missing required runtime prompt file(s)" /tmp/start-swebench-test.err || fail "missing-runtime-prompts error text not found"

  [[ -f "$tmpdir/out/repo__issue-2.status.json" ]] || fail "status file missing when prompt preflight fails"
  [[ -f "$tmpdir/out/repo__issue-2.pred" ]] || fail "pred file missing when prompt preflight fails"
  [[ -f "$tmpdir/out/run_manifest.json" ]] || fail "manifest missing when prompt preflight fails"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__issue-2.status.json").read_text(encoding="utf-8"))
assert status["status"] == "failed"
assert status["failure_reason_code"] == "runtime_error"
assert "Missing required runtime prompt file(s)" in status["failure_reason_detail"]
assert "ralph/prompts/plan.md" in status["error_log"]
assert "ralph/prompts/execute.md" in status["error_log"]
assert "ralph/prompts/handoff.md" in status["error_log"]

pred = json.loads((out / "repo__issue-2.pred").read_text(encoding="utf-8"))
assert pred["model_patch"] == ""

manifest = json.loads((out / "run_manifest.json").read_text(encoding="utf-8"))
inst = manifest["instances"]["repo__issue-2"]
assert inst["status"] == "failed"
assert inst["failure_reason_code"] == "runtime_error"
assert manifest["counts"]["failed"] == 1
PY
}

run_case_missing_required_args
run_case_invalid_max_loops
run_case_default_manifest_and_artifacts
run_case_missing_runtime_prompts

echo "PASS: start-swebench phase1 tests"
