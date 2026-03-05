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
- First command should confirm both locations:
  - `pwd && ls -la {{SWE_BENCH_CODE_DIR}}`
  - `ls -la "$(dirname {{SWE_BENCH_SPEC_PATH}})"`

Next, study [the plan]({{SWE_BENCH_PLAN_PATH}}). The plan describes the implementation steps for the current [spec doc]({{SWE_BENCH_SPEC_PATH}}). Study both of these files. This will get you up to speed on where we are, what we are working on and what's left to do.

Some of the work may have been completed in previous sessions. Audit the code against the spec and the plan to determine what work is left.

If there is no work left to do on this plan, move both `{{SWE_BENCH_SPEC_PATH}}` and `{{SWE_BENCH_PLAN_PATH}}` into `{{SWE_BENCH_ARCHIVE_DIR}}`, then report back that there is nothing left to do and await further instructions.

Assuming there still is work left to do to implement this spec, then do the one most important thing to move the project forward. Pick only the one most important next task and do it.  When it is done, report back and await further instructions.  

Overall completion criteria for this spec (across repeated sessions, not necessarily this session):
- all FAIL_TO_PASS tests pass
- all PASS_TO_PASS tests pass

Do not try to complete everything in one session. In this session, do only the one most important next task toward those criteria, then report back and await further instructions.

Only after all tests are passing, generate the patch and write it to the exact required artifact path: `{{SWE_BENCH_PATCH_PATH}}`.

Patch output contract (critical):
- The final patch file MUST be written to `{{SWE_BENCH_PATCH_PATH}}`.
- Do NOT leave the final patch at `/testbed/model.patch`, `{{SWE_BENCH_CODE_DIR}}/model.patch`, or any `/tmp` path.
- Do NOT delete `{{SWE_BENCH_PATCH_PATH}}` after writing it.

From the repo root (`{{SWE_BENCH_CODE_DIR}}`), run exactly:
```bash
git add -N .
git diff --binary --full-index --no-color HEAD > "{{SWE_BENCH_PATCH_PATH}}"
test -s "{{SWE_BENCH_PATCH_PATH}}" && ls -l "{{SWE_BENCH_PATCH_PATH}}"
```

MCP usage contract (required):
- Use MCP server `swebench_docker_exec`.
- Use only tool calls: `swebench_docker_exec.mcp-docker-exec({"command":"..."})`.
- Do not use `read_mcp_resource`, `list_mcp_resources`, `filesystem.*`, or any other MCP server/method.
- Use shell commands through `mcp-docker-exec` for file reads/writes, tests, inspection, git commands, etc.
- If any MCP call fails, correct by retrying with `swebench_docker_exec.mcp-docker-exec`.

If you find yourself blocked, try to unblock yourself. If you cannot unblock yourself, then update [the plan]({{SWE_BENCH_PLAN_PATH}}) to clearly state what the blockers are. Then you MUST move BOTH the plan and the spec into `{{SWE_BENCH_BLOCKED_DIR}}`. THAT STEP IS CRITICAL.

Remember to keep the planning docs up to date as you work on the task.

That is your workflow. Do these things for the one task you choose. Only complete these things for one task, then report back on status and await further instructions.
