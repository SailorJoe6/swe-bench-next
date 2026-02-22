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
set -euo pipefail

phase="${SWE_BENCH_RUNTIME_PHASE:-unknown}"
plans_dir="${SWE_BENCH_PLANS_DIR:-}"
spec_path="${SWE_BENCH_SPEC_PATH:-$plans_dir/SPECIFICATION.md}"
plan_path="${SWE_BENCH_PLAN_PATH:-$plans_dir/EXECUTION_PLAN.md}"
archive_dir="${SWE_BENCH_ARCHIVE_DIR:-$plans_dir/archive}"
blocked_dir="${SWE_BENCH_BLOCKED_DIR:-$plans_dir/blocked}"
patch_path="${SWE_BENCH_PATCH_PATH:-}"
output_dir="${SWE_BENCH_OUTPUT_DIR:-}"
scenario="${FAKE_CODEX_SCENARIO:-no_op}"

move_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst"
  fi
}

if [[ -n "$output_dir" ]]; then
  mkdir -p "$output_dir/logs"
fi

if [[ "$phase" == "execute" && -n "$output_dir" ]]; then
  count_file="$output_dir/logs/fake_codex_execute_count.txt"
  count=0
  if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
fi

if [[ -n "${FAKE_CODEX_FAIL_PHASE:-}" && "$phase" == "$FAKE_CODEX_FAIL_PHASE" ]]; then
  echo "fake codex forced failure for phase: $phase" >&2
  exit "${FAKE_CODEX_FAIL_EXIT_CODE:-7}"
fi

case "$scenario" in
  no_op|stay_in_root)
    ;;
  blocked_after_first_execute)
    if [[ "$phase" == "execute" && "${SWE_BENCH_EXECUTE_PASS:-0}" == "1" ]]; then
      move_if_exists "$spec_path" "$blocked_dir/SPECIFICATION.md"
      move_if_exists "$plan_path" "$blocked_dir/EXECUTION_PLAN.md"
    fi
    ;;
  archive_with_patch_after_first_execute)
    if [[ "$phase" == "execute" && "${SWE_BENCH_EXECUTE_PASS:-0}" == "1" ]]; then
      move_if_exists "$spec_path" "$archive_dir/SPECIFICATION.md"
      move_if_exists "$plan_path" "$archive_dir/EXECUTION_PLAN.md"
      if [[ -n "$patch_path" ]]; then
        cat > "$patch_path" <<'PATCH'
diff --git a/example.txt b/example.txt
index 1111111..2222222 100644
--- a/example.txt
+++ b/example.txt
@@ -1 +1 @@
-before
+after
PATCH
      fi
    fi
    ;;
  archive_without_patch_after_first_execute)
    if [[ "$phase" == "execute" && "${SWE_BENCH_EXECUTE_PASS:-0}" == "1" ]]; then
      move_if_exists "$spec_path" "$archive_dir/SPECIFICATION.md"
      move_if_exists "$plan_path" "$archive_dir/EXECUTION_PLAN.md"
    fi
    ;;
  *)
    echo "unknown fake codex scenario: $scenario" >&2
    exit 9
    ;;
esac

exit 0
EOF
  chmod +x "$tmpdir/codex"
  echo "$tmpdir"
}

make_fake_docker_bin() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

maybe_fail() {
  local stage="$1"
  if [[ "${FAKE_DOCKER_FAIL_STAGE:-}" == "$stage" ]]; then
    echo "fake docker forced failure at stage: $stage" >&2
    exit "${FAKE_DOCKER_FAIL_EXIT_CODE:-1}"
  fi
}

cmd="${1:-}"
case "$cmd" in
  image)
    subcmd="${2:-}"
    if [[ "$subcmd" == "inspect" ]]; then
      maybe_fail "image_inspect"
      if [[ "${FAKE_DOCKER_IMAGE_EXISTS:-1}" == "1" ]]; then
        exit 0
      fi
      echo "Error: No such image: ${3:-unknown}" >&2
      exit 1
    fi
    ;;
  run)
    maybe_fail "run"
    if [[ "$*" == *"command -v codex"* ]]; then
      if [[ "${FAKE_DOCKER_CONTAINER_HAS_CODEX:-1}" == "1" ]]; then
        exit 0
      fi
      echo "codex not found in container" >&2
      exit 1
    fi
    exit 0
    ;;
  create)
    maybe_fail "create"
    echo "fake-container-id"
    exit 0
    ;;
  start)
    maybe_fail "start"
    exit 0
    ;;
  exec)
    maybe_fail "exec"
    exit 0
    ;;
  cp)
    maybe_fail "cp"
    exit 0
    ;;
  commit)
    maybe_fail "commit"
    exit 0
    ;;
  rm)
    maybe_fail "rm"
    exit 0
    ;;
esac

maybe_fail "${cmd:-unknown}"
exit 0
EOF
  chmod +x "$tmpdir/docker"
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

write_instance_fixture() {
  local fixture_path="$1"
  local instance_id="$2"
  local problem_statement="$3"
  cat > "$fixture_path" <<EOF
{"instance_id":"$instance_id","problem_statement":"$problem_statement"}
EOF
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
  local docker_bin
  local isolated_script
  local instance_fixture
  tmpdir="$(make_isolated_runner_root)"
  codex_bin="$(make_fake_codex_bin)"
  docker_bin="$(make_fake_docker_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  instance_fixture="$tmpdir/instances.jsonl"
  write_required_prompts "$tmpdir"
  write_instance_fixture "$instance_fixture" "repo__issue-1" "Fix the broken parser edge-case in foo/bar."

  set +e
  PATH="$docker_bin:$codex_bin:$PATH" FAKE_DOCKER_IMAGE_EXISTS=1 FAKE_DOCKER_CONTAINER_HAS_CODEX=1 FAKE_CODEX_SCENARIO=stay_in_root SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$isolated_script" --instance-id repo__issue-1 --output-dir "$tmpdir/out" --max-loops 1 > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "20" "$status" "incomplete classification should return 20"

  [[ -f "$tmpdir/out/repo__issue-1.patch" ]] || fail "patch file missing"
  [[ -f "$tmpdir/out/repo__issue-1.pred" ]] || fail "pred file missing"
  [[ -f "$tmpdir/out/repo__issue-1.status.json" ]] || fail "status file missing"
  [[ -f "$tmpdir/out/run_manifest.json" ]] || fail "manifest file missing at default manifest dir"
  [[ -f "$tmpdir/out/logs/codex_command.txt" ]] || fail "codex command lock file missing"
  [[ -f "$tmpdir/out/plans/SPECIFICATION.md" ]] || fail "seeded SPECIFICATION.md missing"
  [[ -f "$tmpdir/out/plans/EXECUTION_PLAN.md" ]] || fail "seeded EXECUTION_PLAN.md missing"

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
assert manifest["last_invocation"]["args"]["max_loops"] == 1

spec_doc = (out / "plans" / "SPECIFICATION.md").read_text(encoding="utf-8")
assert "# Specification: repo__issue-1" in spec_doc
assert "Fix the broken parser edge-case in foo/bar." in spec_doc
assert "dataset: SWE-bench/SWE-bench_Multilingual" in spec_doc

exec_plan_doc = (out / "plans" / "EXECUTION_PLAN.md").read_text(encoding="utf-8")
assert "# Execution Plan: repo__issue-1" in exec_plan_doc
assert "seeded_from: problem_statement" in exec_plan_doc

execute_count = (out / "logs" / "fake_codex_execute_count.txt").read_text(encoding="utf-8").strip()
assert execute_count == "1"
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

run_case_repo_runtime_prompts_available() {
  local tmpdir
  local codex_bin
  local docker_bin
  local instance_fixture
  tmpdir="$(mktemp -d)"
  codex_bin="$(make_fake_codex_bin)"
  docker_bin="$(make_fake_docker_bin)"
  instance_fixture="$tmpdir/instances.jsonl"
  write_instance_fixture "$instance_fixture" "repo__issue-3" "Address the null handling bug in importer."

  set +e
  PATH="$docker_bin:$codex_bin:$PATH" FAKE_DOCKER_IMAGE_EXISTS=1 FAKE_DOCKER_CONTAINER_HAS_CODEX=1 FAKE_CODEX_SCENARIO=stay_in_root SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$SCRIPT" --instance-id repo__issue-3 --output-dir "$tmpdir/out" --max-loops 1 > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "20" "$status" "repo runtime prompts should satisfy preflight and produce incomplete status"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__issue-3.status.json").read_text(encoding="utf-8"))
assert status["status"] == "incomplete"
assert status["failure_reason_code"] == "incomplete"
assert "Missing required runtime prompt file(s)" not in status["failure_reason_detail"]
PY
}

run_case_missing_instance_image() {
  local tmpdir
  local docker_bin
  local isolated_script
  local instance_fixture
  tmpdir="$(make_isolated_runner_root)"
  docker_bin="$(make_fake_docker_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  instance_fixture="$tmpdir/instances.jsonl"
  write_required_prompts "$tmpdir"
  write_instance_fixture "$instance_fixture" "repo__missing-image" "Fix flaky test harness setup."

  set +e
  PATH="$docker_bin:$PATH" FAKE_DOCKER_IMAGE_EXISTS=0 SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$isolated_script" --instance-id repo__missing-image --output-dir "$tmpdir/out" > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "missing instance image should fail invocation"
  rg -F -q -- "Missing required instance image" /tmp/start-swebench-test.err || fail "missing-image error text not found"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__missing-image.status.json").read_text(encoding="utf-8"))
assert status["status"] == "failed"
assert status["failure_reason_code"] == "missing_image"
assert "sweb.eval.arm64.repo__missing-image:latest" in status["failure_reason_detail"]

pred = json.loads((out / "repo__missing-image.pred").read_text(encoding="utf-8"))
assert pred["model_patch"] == ""

manifest = json.loads((out / "run_manifest.json").read_text(encoding="utf-8"))
inst = manifest["instances"]["repo__missing-image"]
assert inst["status"] == "failed"
assert inst["failure_reason_code"] == "missing_image"
PY
}

run_case_codex_bootstrap_failed() {
  local tmpdir
  local docker_bin
  local isolated_script
  local instance_fixture
  local bootstrap_bin
  local bootstrap_config
  tmpdir="$(make_isolated_runner_root)"
  docker_bin="$(make_fake_docker_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  instance_fixture="$tmpdir/instances.jsonl"
  bootstrap_bin="$tmpdir/bootstrap/codex"
  bootstrap_config="$tmpdir/bootstrap/config.toml"
  write_required_prompts "$tmpdir"
  write_instance_fixture "$instance_fixture" "repo__bootstrap-fail" "Repair codex bootstrap path."
  mkdir -p "$tmpdir/bootstrap"
  cat > "$bootstrap_bin" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bootstrap_bin"
  cat > "$bootstrap_config" <<'EOF'
[profiles.local]
provider = "local"
EOF

  set +e
  PATH="$docker_bin:$PATH" FAKE_DOCKER_IMAGE_EXISTS=1 FAKE_DOCKER_CONTAINER_HAS_CODEX=0 FAKE_DOCKER_FAIL_STAGE=cp CODEX_BOOTSTRAP_BIN_PATH="$bootstrap_bin" CODEX_BOOTSTRAP_CONFIG_PATH="$bootstrap_config" SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$isolated_script" --instance-id repo__bootstrap-fail --output-dir "$tmpdir/out" > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "codex bootstrap failure should fail invocation"
  rg -F -q -- "Failed to bootstrap codex in image" /tmp/start-swebench-test.err || fail "codex-bootstrap-failed error text not found"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__bootstrap-fail.status.json").read_text(encoding="utf-8"))
assert status["status"] == "failed"
assert status["failure_reason_code"] == "codex_bootstrap_failed"
assert "Failed to bootstrap codex in image" in status["failure_reason_detail"]

pred = json.loads((out / "repo__bootstrap-fail.pred").read_text(encoding="utf-8"))
assert pred["model_patch"] == ""

manifest = json.loads((out / "run_manifest.json").read_text(encoding="utf-8"))
inst = manifest["instances"]["repo__bootstrap-fail"]
assert inst["status"] == "failed"
assert inst["failure_reason_code"] == "codex_bootstrap_failed"
PY
}

run_case_success_archive_classification() {
  local tmpdir
  local codex_bin
  local docker_bin
  local isolated_script
  local instance_fixture
  tmpdir="$(make_isolated_runner_root)"
  codex_bin="$(make_fake_codex_bin)"
  docker_bin="$(make_fake_docker_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  instance_fixture="$tmpdir/instances.jsonl"
  write_required_prompts "$tmpdir"
  write_instance_fixture "$instance_fixture" "repo__success-case" "Apply patch and archive plans."

  set +e
  PATH="$docker_bin:$codex_bin:$PATH" FAKE_DOCKER_IMAGE_EXISTS=1 FAKE_DOCKER_CONTAINER_HAS_CODEX=1 FAKE_CODEX_SCENARIO=archive_with_patch_after_first_execute SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$isolated_script" --instance-id repo__success-case --output-dir "$tmpdir/out" --max-loops 5 > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "archive state with non-empty patch should return success"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__success-case.status.json").read_text(encoding="utf-8"))
assert status["status"] == "success"
assert status["failure_reason_code"] is None
assert status["failure_reason_detail"] == ""

pred = json.loads((out / "repo__success-case.pred").read_text(encoding="utf-8"))
assert pred["model_patch"] != ""
assert "diff --git" in pred["model_patch"]

manifest = json.loads((out / "run_manifest.json").read_text(encoding="utf-8"))
inst = manifest["instances"]["repo__success-case"]
assert inst["status"] == "success"
assert inst["failure_reason_code"] is None
assert manifest["counts"]["success"] == 1
assert manifest["counts"]["failed"] == 0

assert (out / "plans" / "archive" / "SPECIFICATION.md").exists()
assert (out / "plans" / "archive" / "EXECUTION_PLAN.md").exists()
PY
}

run_case_blocked_terminal_classification() {
  local tmpdir
  local codex_bin
  local docker_bin
  local isolated_script
  local instance_fixture
  tmpdir="$(make_isolated_runner_root)"
  codex_bin="$(make_fake_codex_bin)"
  docker_bin="$(make_fake_docker_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  instance_fixture="$tmpdir/instances.jsonl"
  write_required_prompts "$tmpdir"
  write_instance_fixture "$instance_fixture" "repo__blocked-case" "Move plans to blocked and stop."

  set +e
  PATH="$docker_bin:$codex_bin:$PATH" FAKE_DOCKER_IMAGE_EXISTS=1 FAKE_DOCKER_CONTAINER_HAS_CODEX=1 FAKE_CODEX_SCENARIO=blocked_after_first_execute SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$isolated_script" --instance-id repo__blocked-case --output-dir "$tmpdir/out" --max-loops 5 > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "blocked state should fail invocation"
  rg -F -q -- "entered blocked state" /tmp/start-swebench-test.err || fail "blocked-state error text not found"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__blocked-case.status.json").read_text(encoding="utf-8"))
assert status["status"] == "failed"
assert status["failure_reason_code"] == "blocked"
assert "blocked state" in status["failure_reason_detail"]

pred = json.loads((out / "repo__blocked-case.pred").read_text(encoding="utf-8"))
assert pred["model_patch"] == ""

manifest = json.loads((out / "run_manifest.json").read_text(encoding="utf-8"))
inst = manifest["instances"]["repo__blocked-case"]
assert inst["status"] == "failed"
assert inst["failure_reason_code"] == "blocked"

assert (out / "plans" / "blocked" / "SPECIFICATION.md").exists()
assert (out / "plans" / "blocked" / "EXECUTION_PLAN.md").exists()
PY
}

run_case_max_loops_budget() {
  local tmpdir
  local codex_bin
  local docker_bin
  local isolated_script
  local instance_fixture
  tmpdir="$(make_isolated_runner_root)"
  codex_bin="$(make_fake_codex_bin)"
  docker_bin="$(make_fake_docker_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  instance_fixture="$tmpdir/instances.jsonl"
  write_required_prompts "$tmpdir"
  write_instance_fixture "$instance_fixture" "repo__max-loops-case" "Stay in root state until loop budget is exhausted."

  set +e
  PATH="$docker_bin:$codex_bin:$PATH" FAKE_DOCKER_IMAGE_EXISTS=1 FAKE_DOCKER_CONTAINER_HAS_CODEX=1 FAKE_CODEX_SCENARIO=stay_in_root SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$isolated_script" --instance-id repo__max-loops-case --output-dir "$tmpdir/out" --max-loops 3 > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "20" "$status" "--max-loops exhaustion should report incomplete status"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__max-loops-case.status.json").read_text(encoding="utf-8"))
assert status["status"] == "incomplete"
assert status["failure_reason_code"] == "incomplete"
assert "execute budget" in status["failure_reason_detail"]

execute_count = (out / "logs" / "fake_codex_execute_count.txt").read_text(encoding="utf-8").strip()
assert execute_count == "3"
PY
}

run_case_missing_instance_metadata() {
  local tmpdir
  local codex_bin
  local isolated_script
  local instance_fixture
  tmpdir="$(make_isolated_runner_root)"
  codex_bin="$(make_fake_codex_bin)"
  isolated_script="$tmpdir/scripts/start-swebench.sh"
  instance_fixture="$tmpdir/instances.jsonl"
  write_required_prompts "$tmpdir"
  write_instance_fixture "$instance_fixture" "repo__other-issue" "A different instance that should not match."

  set +e
  PATH="$codex_bin:$PATH" SWE_BENCH_INSTANCES_FILE="$instance_fixture" "$isolated_script" --instance-id repo__missing-issue --output-dir "$tmpdir/out" > /tmp/start-swebench-test.out 2> /tmp/start-swebench-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "missing instance metadata should fail invocation"
  rg -F -q -- "Failed to load instance metadata/problem_statement" /tmp/start-swebench-test.err || fail "missing-instance-metadata error text not found"

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = root / "out"

status = json.loads((out / "repo__missing-issue.status.json").read_text(encoding="utf-8"))
assert status["status"] == "failed"
assert status["failure_reason_code"] == "runtime_error"
assert "Failed to load instance metadata/problem_statement" in status["failure_reason_detail"]
assert "not found" in status["error_log"]
assert "repo__missing-issue" in status["error_log"]

pred = json.loads((out / "repo__missing-issue.pred").read_text(encoding="utf-8"))
assert pred["model_patch"] == ""
PY
}

run_case_missing_required_args
run_case_invalid_max_loops
run_case_default_manifest_and_artifacts
run_case_missing_runtime_prompts
run_case_repo_runtime_prompts_available
run_case_missing_instance_image
run_case_codex_bootstrap_failed
run_case_success_archive_classification
run_case_blocked_terminal_classification
run_case_max_loops_budget
run_case_missing_instance_metadata

echo "PASS: start-swebench phase2 runtime tests"
