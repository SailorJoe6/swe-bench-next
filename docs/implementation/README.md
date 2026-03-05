# Implementation Overview

This folder contains technical implementation documentation for the SWE-Bench evaluation project.

## Documentation Index

- **[Project Status](../project-status.md)** - Current repo status (Phase 3 closed; Phase 5 architecture closeout complete with limited live replay)
- **[Phase 5 Runner](phase5-runner.md)** - Final single-instance and batch runner contract (`start-swebench.sh` + `run-swebench-batch.sh`)
- **[Phase 5 Unresolved Campaign](phase5-unresolved-campaign.md)** - Rerun campaign scaffolding for Phase 3 unresolved IDs (target extraction + prediction campaign runner + sequential eval runner + campaign summary/classification report + post-eval container-defect triage workflow implemented)
- **[MCP Docker Exec Bridge](mcp-docker-exec-bridge.md)** - Phase 2 stdlib MCP bridge server (`mcp-docker-exec`), including February 25, 2026 transport compatibility fix from live integration
- **[Codex Local Bridge](codex-local-bridge.md)** - Required LiteLLM + vLLM runtime chain for `codex -p local`, including repo-local `CODEX_HOME` custom base-instructions override
- **[Prepare Codex Images](prepare-codex-images.md)** - Manual codex image prep utility (`prepare-swebench-codex-images.sh`)
- **[ARM64 Support](../arm64-support/README.md)** - Complete ARM64 implementation guide
- **[Code Changes](../arm64-support/CHANGES.md)** - Detailed code modifications for ARM64
- **[mvnd Fix](../arm64-support/mvnd-fix.md)** - Apache Maven ARM64 binary workaround

## Quick Reference

### Project Structure
```
swebench-eval-next/
├── config/             # SWE-agent configuration files
├── docs/               # Documentation (this directory)
├── scripts/            # vLLM + LiteLLM runtime scripts and utilities
├── results/            # Evaluation outputs (gitignored)
└── ralph/              # AI-assisted development workflow
```

### Evaluation Phases
1. **Phase 1**: vLLM Setup - Deploy Qwen3-Coder-Next-FP8
2. **Phase 2**: Default Harness - Skipped (incompatible with custom vLLM)
3. **Phase 3**: SWE-Agent - Agentic evaluation with ARM64 containers (completed/closed)
4. **Phase 4**: mini-SWE-agent - Optional lightweight agent
5. **Phase 5**: Ralph + Codex local runner workflow (implemented; host-run Codex + MCP shell routing finalized; one live replay complete; one failed-instance integration probe completed with MCP transport fix merged)

## See Also

- **[Quick Start](../guides/quickstart.md)** - For setup and usage instructions
- **[ARM64 Quick Start](../arm64-support/QUICKSTART.md)** - For ARM64-specific setup
