Look to see if you can find any files similar the following in this project:

1. **README.md** - Project overview, features, and configuration
2. **DEVELOPERS.md** - Build setup, development workflow, and testing
3. **docs/README.md** or **docs/index.md** - Documentation index and navigation

Study any such files you find to understand this codebase. If there is no documentation index but there is a documentation folder, at least list its contents so you'll know where to find information you may need later.

Next, study [the plan]({{SWE_BENCH_PLAN_PATH}}). The plan describes the implementation steps for the current [spec doc]({{SWE_BENCH_SPEC_PATH}}). Study both of these files. This will get you up to speed on where we are, what we are working on and what's left to do.

Some of the work may have been completed in previous sessions. Audit the code against the spec and the plan to determine what work is left.

If there is no work left to do on this plan, then check if the spec has been completely converted to a document (or set of documents) in the `docs/` folder describing the new state of this code. If that hasn't been done, then doing so is your next task.

If the plan is truly finished, all changes are documented and there is nothing left to do on this plan, move both `{{SWE_BENCH_SPEC_PATH}}` and `{{SWE_BENCH_PLAN_PATH}}` into `{{SWE_BENCH_ARCHIVE_DIR}}`, then report back that there is nothing left to do and await further instructions.

Assuming there still is work left to do to implement this spec, then do the one most important thing to move the project forward. Pick only the one most important next task and do it.  When it is done, report back and await further instructions.  

If you find yourself blocked, try to unblock yourself. If you cannot unblock yourself, then update [the plan]({{SWE_BENCH_PLAN_PATH}}) to clearly state what the blockers are. Then you MUST move BOTH the plan and the spec into `{{SWE_BENCH_BLOCKED_DIR}}`. THAT STEP IS CRITICAL.

Remember to keep the planning docs up to date as you work on the task.

That is your workflow. Do these things for the one task you choose. Only complete these things for one task, then report back on status and await further instructions.
