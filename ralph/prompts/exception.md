Your job is verification and artifact finalization only.  This a verification and artifact "clean up" pass.

Use these paths:
- Code directory: `{{SWE_BENCH_CODE_DIR}}`
- Spec doc (root): `{{SWE_BENCH_SPEC_PATH}}`
- Plan doc (root): `{{SWE_BENCH_PLAN_PATH}}`
- Archive dir: `{{SWE_BENCH_ARCHIVE_DIR}}`
- Blocked dir: `{{SWE_BENCH_BLOCKED_DIR}}`
- Required patch path: `{{SWE_BENCH_PATCH_PATH}}`

What to do:
1. Run the full test suite(s) for this repository from `{{SWE_BENCH_CODE_DIR}}`.
2. Do not modify source code in this pass, just run tests and decide what to do based on the following:
3. If tests pass:
   - Generate a non-empty patch at `{{SWE_BENCH_PATCH_PATH}}` (final path only).
     From the repo root (`{{SWE_BENCH_CODE_DIR}}`), run exactly:
     ```bash
     git add -N .
     git diff --binary --full-index --no-color HEAD > "{{SWE_BENCH_PATCH_PATH}}"
     test -s "{{SWE_BENCH_PATCH_PATH}}" && ls -l "{{SWE_BENCH_PATCH_PATH}}"
     ```
   - Ensure both planning docs end up in archive as:
     - `{{SWE_BENCH_ARCHIVE_DIR}}/SPECIFICATION.md`
     - `{{SWE_BENCH_ARCHIVE_DIR}}/EXECUTION_PLAN.md`
4. If tests fail or cannot be run:
   - Don't generate any patch.  
   - Ensure both planning docs end up in blocked as:
     - `{{SWE_BENCH_BLOCKED_DIR}}/SPECIFICATION.md`
     - `{{SWE_BENCH_BLOCKED_DIR}}/EXECUTION_PLAN.md`
5. Stop after these steps. 

Constraints:
- No feature work, no refactors, no root-cause investigation.
- No git history commands (`git log`, `git show`, `git blame`, etc.).
- Do not write alternate patch files.

MCP contract:
- Use only `swebench_docker_exec.mcp-docker-exec({"command":"..."})`.
