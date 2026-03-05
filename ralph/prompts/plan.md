Look to see if you can find any files similar the following in this project:

1. **README.md** - Project overview, features, and configuration
2. **DEVELOPERS.md** - Build setup, development workflow, and testing
3. **docs/README.md** or **docs/index.md** - Documentation index and navigation

Study any such files you find to understand this codebase. If there is no documentation index but there is a documentation folder, at least list its contents so you'll know where to find information you may need later.

Path contract (critical):
- `{{SWE_BENCH_SPEC_PATH}}` and `{{SWE_BENCH_PLAN_PATH}}` are planning docs in the mounted results directory.
- The source repository is at `{{SWE_BENCH_CODE_DIR}}` (typically `/testbed`).
- Read/write source files, run tests, and run git commands from `{{SWE_BENCH_CODE_DIR}}`.
- Do not treat the plans/spec directory as the source tree.

MCP usage contract (required):
- Use MCP server `swebench_docker_exec`.
- Use only tool calls: `swebench_docker_exec.mcp-docker-exec({"command":"..."})`.
- Do not use `read_mcp_resource`, `list_mcp_resources`, `filesystem.*`, or any other MCP server/method.
- Use shell commands through `mcp-docker-exec` for file reads/writes, tests, and inspection.
- First run a quick sanity command via the tool, then continue work. At minimum verify both paths:
  - `pwd && ls -la {{SWE_BENCH_CODE_DIR}}`
  - `ls -la "$(dirname {{SWE_BENCH_SPEC_PATH}})"`

After you have studied those files, study [the spec]({{SWE_BENCH_SPEC_PATH}}) to understand the changes we are currently working on. Then audit the current status of the project against this spec to determine what work needs to be done. Use this information to develop a new document `{{SWE_BENCH_PLAN_PATH}}`. This will hold your plan of action for implementing the spec.  

Your plan MUST at a minimum include:
- run all FAIL_TO_PASS tests and observe the issue described in the spec.
- any/all work required to make all tests pass
- run all tests (FAIL_TO_PASS and PASS_TO_PASS) and observe a green test suite

Your primary goal is to write [the execution plan]({{SWE_BENCH_PLAN_PATH}}), not to fix this issue.  Write the execution plan, then stop.
