#!/usr/bin/env python3
"""Minimal stdio MCP server that routes shell commands through docker exec."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


SERVER_NAME = "mcp-docker-exec-server"
SERVER_VERSION = "0.1.0"
TOOL_NAME = "mcp-docker-exec"
SUPPORTED_PROTOCOL_VERSION = "2024-11-05"
TRANSPORT_CONTENT_LENGTH = "content_length"
TRANSPORT_LINE = "line"
RESOURCE_URI = "mcp://mcp-docker-exec-server/usage"


@dataclass(frozen=True)
class RuntimeBindings:
    container_name: str
    workdir: str
    command_timeout_seconds: float | None


def parse_args() -> RuntimeBindings:
    parser = argparse.ArgumentParser(
        description=(
            "Run a minimal MCP stdio server exposing only mcp-docker-exec. "
            "Container name and workdir bindings are required."
        )
    )
    parser.add_argument(
        "--container-name",
        default=os.environ.get("SWE_BENCH_RUNTIME_CONTAINER_NAME", ""),
        help="Target runtime container name (default: SWE_BENCH_RUNTIME_CONTAINER_NAME).",
    )
    parser.add_argument(
        "--workdir",
        default=(
            os.environ.get("SWE_BENCH_RUNTIME_CONTAINER_WORKDIR")
            or os.environ.get("SWE_BENCH_CONTAINER_WORKDIR", "")
        ),
        help=(
            "Fixed workdir inside container "
            "(default: SWE_BENCH_RUNTIME_CONTAINER_WORKDIR or SWE_BENCH_CONTAINER_WORKDIR)."
        ),
    )
    parser.add_argument(
        "--command-timeout-seconds",
        default=os.environ.get("SWE_BENCH_MCP_DOCKER_EXEC_TIMEOUT_SECONDS", "55"),
        help=(
            "Maximum seconds for one docker-exec tool call "
            "(default: SWE_BENCH_MCP_DOCKER_EXEC_TIMEOUT_SECONDS or 55; <=0 disables timeout)."
        ),
    )
    args = parser.parse_args()

    missing: list[str] = []
    container_name = args.container_name.strip()
    workdir = args.workdir.strip()

    if not container_name:
        missing.append("--container-name/SWE_BENCH_RUNTIME_CONTAINER_NAME")
    if not workdir:
        missing.append(
            "--workdir/SWE_BENCH_RUNTIME_CONTAINER_WORKDIR/SWE_BENCH_CONTAINER_WORKDIR"
        )
    if missing:
        parser.error("missing required runtime bindings: " + ", ".join(missing))

    timeout_raw = str(args.command_timeout_seconds).strip()
    try:
        timeout_value = float(timeout_raw)
    except ValueError as exc:
        parser.error(f"invalid --command-timeout-seconds value: {timeout_raw}")  # pragma: no cover
        raise exc

    timeout_seconds = timeout_value if timeout_value > 0 else None
    return RuntimeBindings(
        container_name=container_name,
        workdir=workdir,
        command_timeout_seconds=timeout_seconds,
    )


def _jsonrpc_result(message_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def _jsonrpc_error(message_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def _tool_result(payload: dict[str, Any], is_error: bool) -> dict[str, Any]:
    text_payload = json.dumps(payload, ensure_ascii=False)
    return {
        "content": [{"type": "text", "text": text_payload}],
        "structuredContent": payload,
        "isError": is_error,
    }


def _tool_definition() -> dict[str, Any]:
    return {
        "name": TOOL_NAME,
        "description": "Execute a shell command in a prebound runtime container/workdir.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "command": {
                    "type": "string",
                    "description": "Command string executed as /bin/sh -lc <command>.",
                },
                "timeout_seconds": {
                    "type": "number",
                    "description": "Optional per-call timeout in seconds. Must be > 0.",
                },
            },
            "required": ["command"],
        },
    }


def _resource_definition() -> dict[str, Any]:
    return {
        "uri": RESOURCE_URI,
        "name": "mcp-docker-exec usage",
        "description": "How to use the tool-only docker exec MCP bridge.",
        "mimeType": "text/markdown",
    }


def _resource_content(bindings: RuntimeBindings) -> dict[str, Any]:
    text = "\n".join(
        [
            "# MCP Docker Exec Bridge",
            "",
            "This MCP server exposes one tool:",
            f"- `{TOOL_NAME}`",
            "",
            "Runtime bindings:",
            f"- container: `{bindings.container_name}`",
            f"- workdir: `{bindings.workdir}`",
            "",
            "Usage:",
            "1. Call `tools/list` to discover available tools.",
            "2. Call `tools/call` with:",
            f'   - `name`: `{TOOL_NAME}`',
            '   - `arguments`: `{"command":"<shell command>"}`',
            "",
            "Command execution path:",
            "- docker exec -i -w <workdir> <container> /bin/sh -lc <command>",
            "",
            "Notes:",
            "- This server is tool-first and does not expose a filesystem browser.",
            "- Use shell commands for file reads/writes, tests, and inspections.",
            (
                "- Default per-call timeout: "
                + (
                    f"{bindings.command_timeout_seconds:g}s"
                    if bindings.command_timeout_seconds is not None
                    else "disabled"
                )
            ),
        ]
    )
    return {
        "uri": RESOURCE_URI,
        "mimeType": "text/markdown",
        "text": text,
    }


def _run_docker_exec(
    bindings: RuntimeBindings, command: str, timeout_seconds: float | None
) -> dict[str, Any]:
    cmd = [
        "docker",
        "exec",
        "-i",
        "-w",
        bindings.workdir,
        bindings.container_name,
        "/bin/sh",
        "-lc",
        command,
    ]
    try:
        completed = subprocess.run(
            cmd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_seconds,
        )
        return {
            "exit_code": completed.returncode,
            "stdout": completed.stdout.decode("utf-8", errors="replace"),
            "stderr": completed.stderr.decode("utf-8", errors="replace"),
        }
    except subprocess.TimeoutExpired as exc:
        stdout_bytes = exc.stdout if isinstance(exc.stdout, bytes) else (exc.stdout or "").encode("utf-8")
        stderr_bytes = exc.stderr if isinstance(exc.stderr, bytes) else (exc.stderr or "").encode("utf-8")
        timeout_text = f"docker exec command timed out after {timeout_seconds:g}s"
        stderr = stderr_bytes.decode("utf-8", errors="replace")
        stderr = f"{stderr}\n{timeout_text}".lstrip("\n")
        return {
            "exit_code": 124,
            "stdout": stdout_bytes.decode("utf-8", errors="replace"),
            "stderr": stderr,
        }


def _handle_tools_call(message_id: Any, params: Any, bindings: RuntimeBindings) -> dict[str, Any]:
    if not isinstance(params, dict):
        return _jsonrpc_result(
            message_id,
            _tool_result({"error": "tools/call params must be an object"}, is_error=True),
        )

    tool_name = params.get("name")
    if tool_name != TOOL_NAME:
        return _jsonrpc_result(
            message_id,
            _tool_result({"error": f"unknown tool '{tool_name}'"}, is_error=True),
        )

    arguments = params.get("arguments")
    if not isinstance(arguments, dict):
        return _jsonrpc_result(
            message_id,
            _tool_result({"error": "tools/call arguments must be an object"}, is_error=True),
        )

    command = arguments.get("command")
    if not isinstance(command, str) or not command.strip():
        return _jsonrpc_result(
            message_id,
            _tool_result(
                {"error": "argument 'command' must be a non-empty string"},
                is_error=True,
            ),
        )

    timeout_value = bindings.command_timeout_seconds
    if "timeout_seconds" in arguments:
        raw_timeout = arguments.get("timeout_seconds")
        if not isinstance(raw_timeout, (int, float)) or raw_timeout <= 0:
            return _jsonrpc_result(
                message_id,
                _tool_result(
                    {"error": "argument 'timeout_seconds' must be a number > 0"},
                    is_error=True,
                ),
            )
        timeout_value = float(raw_timeout)

    try:
        payload = _run_docker_exec(bindings, command, timeout_value)
    except OSError as exc:
        return _jsonrpc_result(
            message_id,
            _tool_result(
                {"error": f"failed to execute docker: {exc}"},
                is_error=True,
            ),
        )

    return _jsonrpc_result(message_id, _tool_result(payload, is_error=False))


def _handle_resources_read(message_id: Any, params: Any, bindings: RuntimeBindings) -> dict[str, Any]:
    if not isinstance(params, dict):
        return _jsonrpc_error(message_id, -32602, "resources/read params must be an object")

    uri = params.get("uri")
    if not isinstance(uri, str) or not uri.strip():
        return _jsonrpc_error(message_id, -32602, "resources/read requires a non-empty 'uri' string")

    if uri != RESOURCE_URI:
        return _jsonrpc_error(message_id, -32602, f"unknown resource '{uri}'")

    return _jsonrpc_result(message_id, {"contents": [_resource_content(bindings)]})


def _handle_message(message: Any, bindings: RuntimeBindings) -> dict[str, Any] | None:
    if not isinstance(message, dict):
        return None

    method = message.get("method")
    message_id = message.get("id")
    params = message.get("params", {})

    if not isinstance(method, str):
        if message_id is None:
            return None
        return _jsonrpc_error(message_id, -32600, "Invalid Request")

    if method == "initialize":
        client_version = None
        if isinstance(params, dict):
            client_version = params.get("protocolVersion")
        protocol_version = client_version if isinstance(client_version, str) else SUPPORTED_PROTOCOL_VERSION
        return _jsonrpc_result(
            message_id,
            {
                "protocolVersion": protocol_version,
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        )

    if method == "notifications/initialized":
        return None

    if method == "tools/list":
        return _jsonrpc_result(message_id, {"tools": [_tool_definition()]})

    if method == "resources/list":
        return _jsonrpc_result(message_id, {"resources": [_resource_definition()]})

    if method == "resources/read":
        return _handle_resources_read(message_id, params, bindings)

    if method == "tools/call":
        return _handle_tools_call(message_id, params, bindings)

    if message_id is None:
        return None
    return _jsonrpc_error(message_id, -32601, f"Method not found: {method}")


def _parse_message_body(payload: bytes) -> dict[str, Any]:
    decoded = payload.decode("utf-8", errors="strict")
    parsed = json.loads(decoded)
    if not isinstance(parsed, dict):
        raise ValueError("message body must be a JSON object")
    return parsed

def _read_content_length_message(
    input_stream: Any, first_header_line: bytes
) -> tuple[dict[str, Any] | None, str]:
    content_length: int | None = None
    line = first_header_line

    while True:
        if line == b"":
            return None, TRANSPORT_CONTENT_LENGTH
        if line in (b"\r\n", b"\n"):
            break

        header = line.decode("utf-8", errors="replace").strip()
        if header:
            key, sep, value = header.partition(":")
            if sep and key.lower() == "content-length":
                try:
                    content_length = int(value.strip())
                except ValueError as exc:
                    raise ValueError(f"invalid Content-Length header: {header}") from exc

        line = input_stream.readline()

    if content_length is None:
        raise ValueError("missing Content-Length header")

    payload = input_stream.read(content_length)
    if len(payload) != content_length:
        raise EOFError("unexpected EOF while reading message body")

    return _parse_message_body(payload), TRANSPORT_CONTENT_LENGTH


def _read_line_message(first_line: bytes) -> tuple[dict[str, Any], str]:
    stripped = first_line.strip()
    if not stripped:
        raise ValueError("empty line-delimited MCP message")
    return _parse_message_body(stripped), TRANSPORT_LINE


def _read_message(input_stream: Any) -> tuple[dict[str, Any] | None, str | None]:
    while True:
        first_line = input_stream.readline()
        if first_line == b"":
            return None, None
        if first_line in (b"\r\n", b"\n"):
            continue

        stripped = first_line.lstrip()
        if stripped.startswith((b"{", b"[")):
            return _read_line_message(first_line)
        return _read_content_length_message(input_stream, first_line)


def _write_message(output_stream: Any, message: dict[str, Any], transport: str) -> None:
    encoded = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if transport == TRANSPORT_LINE:
        output_stream.write(encoded + b"\n")
    else:
        header = f"Content-Length: {len(encoded)}\r\n\r\n".encode("ascii")
        output_stream.write(header)
        output_stream.write(encoded)
    output_stream.flush()


def serve(bindings: RuntimeBindings) -> int:
    input_stream = sys.stdin.buffer
    output_stream = sys.stdout.buffer

    while True:
        try:
            message, transport = _read_message(input_stream)
        except Exception as exc:  # pragma: no cover - protocol violation branch
            print(f"{SERVER_NAME}: protocol error: {exc}", file=sys.stderr)
            return 1

        if message is None:
            return 0

        response = _handle_message(message, bindings)
        if response is None:
            continue
        _write_message(output_stream, response, transport or TRANSPORT_CONTENT_LENGTH)


def main() -> int:
    bindings = parse_args()
    return serve(bindings)


if __name__ == "__main__":
    raise SystemExit(main())
