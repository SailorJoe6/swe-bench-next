Look to see if you can find any files similar the following in this project:

1. **README.md** - Project overview, features, and configuration
2. **DEVELOPERS.md** - Build setup, development workflow, and testing
3. **docs/README.md** or **docs/index.md** - Documentation index and navigation

Study any such files you find to understand this codebase. If there is no documentation index but there is a documentation folder, at least list its contents so you'll know where to find information you may need later.

After you have studied those files, study [the spec]({{SWE_BENCH_SPEC_PATH}}) to understand the changes we are currently working on. Then audit the current status of the project against this spec to determine what work needs to be done. Use this information to develop a new document `{{SWE_BENCH_PLAN_PATH}}`. This will hold your plan of action for implementing the spec.  

Your plan MUST at a minimum include:
- run all FAIL_TO_PASS tests and observe the issue described in the spec.
- any/all work required to make all tests pass
- run all tests (FAIL_TO_PASS and PASS_TO_PASS) and observe a green test suite

Your primary goal is to write [the execution plan]({{SWE_BENCH_PLAN_PATH}}), not to fix this issue.  Write the execution plan, then stop.
