#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_SCRIPT="$REPO_ROOT/scripts/mcp-docker-exec-server.py"

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

make_fake_docker_bin() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "exec" ]]; then
  echo "fake docker only supports exec, got: ${1:-<none>}" >&2
  exit 97
fi

shift
if [[ -n "${FAKE_DOCKER_LOG_PATH:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "$arg" >> "$FAKE_DOCKER_LOG_PATH"
  done
  printf -- '--\n' >> "$FAKE_DOCKER_LOG_PATH"
fi

if [[ -n "${FAKE_DOCKER_STDOUT:-}" ]]; then
  printf '%b' "${FAKE_DOCKER_STDOUT}"
fi
if [[ -n "${FAKE_DOCKER_STDERR:-}" ]]; then
  printf '%b' "${FAKE_DOCKER_STDERR}" >&2
fi

exit "${FAKE_DOCKER_EXIT_CODE:-0}"
EOF
  chmod +x "$tmpdir/docker"
  echo "$tmpdir"
}

run_case_missing_bindings() {
  set +e
  python3 "$SERVER_SCRIPT" >/tmp/test-mcp-server.out 2>/tmp/test-mcp-server.err
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    fail "server should fail startup when required bindings are missing"
  fi
  rg -q "missing required runtime bindings" /tmp/test-mcp-server.err || fail "missing startup binding error text not found"
}

run_case_stdio_protocol_and_passthrough() {
  local docker_dir
  local docker_log
  local tmpdir
  tmpdir="$(mktemp -d)"
  docker_dir="$(make_fake_docker_bin)"
  docker_log="$tmpdir/docker.log"

  PATH="$docker_dir:$PATH" \
  FAKE_DOCKER_LOG_PATH="$docker_log" \
  FAKE_DOCKER_STDOUT=$'docker-stdout-line-1\ndocker-stdout-line-2\n' \
  FAKE_DOCKER_STDERR=$'docker-stderr-line-1\n' \
  FAKE_DOCKER_EXIT_CODE=17 \
  python3 - "$SERVER_SCRIPT" "$docker_log" <<'PY'
import json
import pathlib
import subprocess
import sys

server_script = sys.argv[1]
docker_log = pathlib.Path(sys.argv[2])


def send_message(pipe, payload):
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    pipe.write(header + body)
    pipe.flush()


def recv_message(pipe):
    content_length = None
    while True:
        line = pipe.readline()
        if line == b"":
            raise RuntimeError("unexpected EOF while reading headers")
        if line in (b"\r\n", b"\n"):
            break
        header = line.decode("utf-8").strip()
        key, sep, value = header.partition(":")
        if sep and key.lower() == "content-length":
            content_length = int(value.strip())
    if content_length is None:
        raise RuntimeError("missing Content-Length in response")
    body = pipe.read(content_length)
    if len(body) != content_length:
        raise RuntimeError("incomplete message body")
    return json.loads(body.decode("utf-8"))


proc = subprocess.Popen(
    [sys.executable, server_script, "--container-name", "runtime-demo", "--workdir", "/testbed"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

assert proc.stdin is not None
assert proc.stdout is not None
assert proc.stderr is not None

send_message(
    proc.stdin,
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test"}},
    },
)
init_resp = recv_message(proc.stdout)
assert init_resp["id"] == 1
assert init_resp["result"]["protocolVersion"] == "2024-11-05"

send_message(proc.stdin, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

send_message(proc.stdin, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
list_resp = recv_message(proc.stdout)
tools = list_resp["result"]["tools"]
assert isinstance(tools, list) and len(tools) == 1
assert tools[0]["name"] == "mcp-docker-exec"

send_message(
    proc.stdin,
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "mcp-docker-exec", "arguments": {}},
    },
)
invalid_resp = recv_message(proc.stdout)
assert invalid_resp["result"]["isError"] is True
assert "command" in invalid_resp["result"]["structuredContent"]["error"]

send_message(
    proc.stdin,
    {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {
            "name": "mcp-docker-exec",
            "arguments": {"command": "echo hello from mcp"},
        },
    },
)
call_resp = recv_message(proc.stdout)
assert call_resp["result"]["isError"] is False

payload = call_resp["result"]["structuredContent"]
assert payload["exit_code"] == 17
assert payload["stdout"] == "docker-stdout-line-1\ndocker-stdout-line-2\n"
assert payload["stderr"] == "docker-stderr-line-1\n"

content_payload = json.loads(call_resp["result"]["content"][0]["text"])
assert content_payload == payload

proc.stdin.close()
return_code = proc.wait(timeout=5)
stderr_text = proc.stderr.read().decode("utf-8")
assert return_code == 0, stderr_text

logged = docker_log.read_text(encoding="utf-8").splitlines()
expected = [
    "-i",
    "-w",
    "/testbed",
    "runtime-demo",
    "/bin/sh",
    "-lc",
    "echo hello from mcp",
    "--",
]
assert logged == expected, logged
PY
}

run_case_line_delimited_protocol_and_passthrough() {
  local docker_dir
  local docker_log
  local tmpdir
  tmpdir="$(mktemp -d)"
  docker_dir="$(make_fake_docker_bin)"
  docker_log="$tmpdir/docker.log"

  PATH="$docker_dir:$PATH" \
  FAKE_DOCKER_LOG_PATH="$docker_log" \
  FAKE_DOCKER_STDOUT=$'line-stdout\n' \
  FAKE_DOCKER_STDERR=$'line-stderr\n' \
  FAKE_DOCKER_EXIT_CODE=23 \
  python3 - "$SERVER_SCRIPT" "$docker_log" <<'PY'
import json
import pathlib
import subprocess
import sys

server_script = sys.argv[1]
docker_log = pathlib.Path(sys.argv[2])


def send_line(pipe, payload):
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
    pipe.write(body)
    pipe.flush()


def recv_line(pipe):
    line = pipe.readline()
    if line == b"":
        raise RuntimeError("unexpected EOF while reading line-delimited MCP response")
    return json.loads(line.decode("utf-8"))


proc = subprocess.Popen(
    [sys.executable, server_script, "--container-name", "runtime-line", "--workdir", "/testbed"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

assert proc.stdin is not None
assert proc.stdout is not None
assert proc.stderr is not None

send_line(
    proc.stdin,
    {
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test"}},
    },
)
init_resp = recv_line(proc.stdout)
assert init_resp["id"] == 0
assert init_resp["result"]["protocolVersion"] == "2025-06-18"

send_line(proc.stdin, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

send_line(proc.stdin, {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
list_resp = recv_line(proc.stdout)
tools = list_resp["result"]["tools"]
assert isinstance(tools, list) and len(tools) == 1
assert tools[0]["name"] == "mcp-docker-exec"

send_line(
    proc.stdin,
    {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "mcp-docker-exec",
            "arguments": {"command": "echo line protocol"},
        },
    },
)
call_resp = recv_line(proc.stdout)
assert call_resp["result"]["isError"] is False
payload = call_resp["result"]["structuredContent"]
assert payload["exit_code"] == 23
assert payload["stdout"] == "line-stdout\n"
assert payload["stderr"] == "line-stderr\n"

proc.stdin.close()
return_code = proc.wait(timeout=5)
stderr_text = proc.stderr.read().decode("utf-8")
assert return_code == 0, stderr_text

logged = docker_log.read_text(encoding="utf-8").splitlines()
expected = [
    "-i",
    "-w",
    "/testbed",
    "runtime-line",
    "/bin/sh",
    "-lc",
    "echo line protocol",
    "--",
]
assert logged == expected, logged
PY
}

run_case_missing_bindings
run_case_stdio_protocol_and_passthrough
run_case_line_delimited_protocol_and_passthrough

echo "PASS: mcp docker exec server"
