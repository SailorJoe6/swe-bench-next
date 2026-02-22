#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/prepare-swebench-codex-images.sh"

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
  cp "$SCRIPT" "$tmpdir/scripts/prepare-swebench-codex-images.sh"
  chmod +x "$tmpdir/scripts/prepare-swebench-codex-images.sh"
  echo "$tmpdir"
}

make_fake_bootstrap_sources() {
  local root="$1"
  local bin_path="$root/bootstrap/codex"
  local config_path="$root/bootstrap/config.toml"

  mkdir -p "$root/bootstrap"
  cat > "$bin_path" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_path"

  cat > "$config_path" <<'EOF'
[profiles.local]
provider = "local"
EOF

  echo "$bin_path|$config_path"
}

make_fake_docker_bin() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log() {
  if [[ -n "${FAKE_DOCKER_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
  fi
}

contains_csv() {
  local target="$1"
  local csv="${2:-}"
  local item=""
  IFS=',' read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    if [[ "$item" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

cmd="${1:-}"
shift || true

log "$cmd $*"

case "$cmd" in
  images)
    if [[ "${1:-}" != "--format" ]]; then
      echo "unsupported images invocation" >&2
      exit 2
    fi
    IFS=',' read -r -a items <<< "${FAKE_DOCKER_IMAGES:-}"
    for item in "${items[@]}"; do
      if [[ -n "$item" ]]; then
        printf '%s\n' "$item"
      fi
    done
    exit 0
    ;;
  image)
    subcmd="${1:-}"
    image_ref="${2:-}"
    if [[ "$subcmd" != "inspect" ]]; then
      echo "unsupported image subcommand: $subcmd" >&2
      exit 2
    fi
    if contains_csv "$image_ref" "${FAKE_DOCKER_IMAGES:-}"; then
      exit 0
    fi
    echo "Error: No such image: $image_ref" >&2
    exit 1
    ;;
  create)
    echo "fake-container-id"
    exit 0
    ;;
  start|exec|cp|rm)
    exit 0
    ;;
  commit)
    if [[ "${FAKE_DOCKER_FAIL_COMMIT:-0}" == "1" ]]; then
      echo "forced commit failure" >&2
      exit 1
    fi
    exit 0
    ;;
  run)
    if [[ "${FAKE_DOCKER_FAIL_VERIFY:-0}" == "1" ]]; then
      echo "forced verify failure" >&2
      exit 1
    fi
    exit 0
    ;;
esac

echo "unsupported docker invocation: $cmd" >&2
exit 2
EOF
  chmod +x "$tmpdir/docker"
  echo "$tmpdir"
}

run_case_requires_selector() {
  set +e
  "$SCRIPT" > /tmp/prepare-swebench-test.out 2> /tmp/prepare-swebench-test.err
  local status=$?
  set -e

  assert_eq "2" "$status" "missing selectors should fail validation"
  rg -q "at least one target selector is required" /tmp/prepare-swebench-test.err || fail "missing selector error text not found"
}

run_case_success_with_instance_file_and_all_local() {
  local tmpdir
  local docker_bin
  local script_path
  local bootstrap_paths
  local codex_bin
  local codex_config
  local instance_file
  local docker_log
  tmpdir="$(make_isolated_root)"
  docker_bin="$(make_fake_docker_bin)"
  script_path="$tmpdir/scripts/prepare-swebench-codex-images.sh"
  bootstrap_paths="$(make_fake_bootstrap_sources "$tmpdir")"
  codex_bin="${bootstrap_paths%%|*}"
  codex_config="${bootstrap_paths##*|}"
  instance_file="$tmpdir/instances.txt"
  docker_log="$tmpdir/docker.log"

  cat > "$instance_file" <<'EOF'
repo__gamma-3
repo__alpha-1
EOF

  set +e
  PATH="$docker_bin:$PATH" \
  FAKE_DOCKER_LOG="$docker_log" \
  FAKE_DOCKER_IMAGES="sweb.eval.arm64.repo__alpha-1:latest,sweb.eval.arm64.repo__beta-2:latest,sweb.eval.arm64.repo__gamma-3:latest,sweb.eval.arm64.repo__alpha-1:dev,other.repo:latest" \
  CODEX_BOOTSTRAP_BIN_PATH="$codex_bin" \
  CODEX_BOOTSTRAP_CONFIG_PATH="$codex_config" \
    "$script_path" --instance-id repo__beta-2 --instance-file "$instance_file" --all-local-images > /tmp/prepare-swebench-test.out 2> /tmp/prepare-swebench-test.err
  local status=$?
  set -e

  assert_eq "0" "$status" "prepare utility should succeed for resolved targets"

  python3 - "$docker_log" <<'PY'
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
lines = [line.strip() for line in log_path.read_text(encoding="utf-8").splitlines() if line.strip()]

commit_targets = []
for line in lines:
    if line.startswith("commit "):
        parts = line.split()
        commit_targets.append(parts[-1])

assert commit_targets == [
    "sweb.eval.arm64.repo__alpha-1:latest",
    "sweb.eval.arm64.repo__beta-2:latest",
    "sweb.eval.arm64.repo__gamma-3:latest",
], commit_targets

verify_runs = [line for line in lines if line.startswith("run ")]
assert len(verify_runs) == 3, verify_runs
PY
}

run_case_missing_bootstrap_binary() {
  local tmpdir
  local docker_bin
  local script_path
  local docker_log
  tmpdir="$(make_isolated_root)"
  docker_bin="$(make_fake_docker_bin)"
  script_path="$tmpdir/scripts/prepare-swebench-codex-images.sh"
  docker_log="$tmpdir/docker.log"

  set +e
  PATH="$docker_bin:$PATH" \
  FAKE_DOCKER_LOG="$docker_log" \
  FAKE_DOCKER_IMAGES="sweb.eval.arm64.repo__alpha-1:latest" \
  CODEX_BOOTSTRAP_BIN_PATH="$tmpdir/missing/codex" \
    "$script_path" --instance-id repo__alpha-1 > /tmp/prepare-swebench-test.out 2> /tmp/prepare-swebench-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "missing bootstrap binary should fail"
  rg -q "codex bootstrap binary is missing or not executable" /tmp/prepare-swebench-test.err || fail "missing bootstrap binary error text not found"

  if [[ -f "$docker_log" ]]; then
    ! rg -q "^commit " "$docker_log" || fail "should not commit images when bootstrap source is missing"
  fi
}

run_case_partial_failure_missing_image() {
  local tmpdir
  local docker_bin
  local script_path
  local bootstrap_paths
  local codex_bin
  local codex_config
  local docker_log
  tmpdir="$(make_isolated_root)"
  docker_bin="$(make_fake_docker_bin)"
  script_path="$tmpdir/scripts/prepare-swebench-codex-images.sh"
  bootstrap_paths="$(make_fake_bootstrap_sources "$tmpdir")"
  codex_bin="${bootstrap_paths%%|*}"
  codex_config="${bootstrap_paths##*|}"
  docker_log="$tmpdir/docker.log"

  set +e
  PATH="$docker_bin:$PATH" \
  FAKE_DOCKER_LOG="$docker_log" \
  FAKE_DOCKER_IMAGES="sweb.eval.arm64.repo__alpha-1:latest" \
  CODEX_BOOTSTRAP_BIN_PATH="$codex_bin" \
  CODEX_BOOTSTRAP_CONFIG_PATH="$codex_config" \
    "$script_path" --instance-id repo__alpha-1 --instance-id repo__missing-9 > /tmp/prepare-swebench-test.out 2> /tmp/prepare-swebench-test.err
  local status=$?
  set -e

  assert_eq "1" "$status" "missing image should fail overall run"
  rg -q "image not found: sweb.eval.arm64.repo__missing-9:latest" /tmp/prepare-swebench-test.err || fail "missing image error text not found"

  python3 - "$docker_log" <<'PY'
import pathlib
import sys

lines = [line.strip() for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
commit_targets = [line.split()[-1] for line in lines if line.startswith("commit ")]
assert commit_targets == ["sweb.eval.arm64.repo__alpha-1:latest"], commit_targets
PY
}

run_case_requires_selector
run_case_success_with_instance_file_and_all_local
run_case_missing_bootstrap_binary
run_case_partial_failure_missing_image

echo "PASS: prepare-swebench-codex-images tests"
