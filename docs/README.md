# Documentation Index

Welcome to the SWE-Bench Evaluation project documentation. This index provides quick access to all documentation.

## Getting Started

- **[Quick Start](guides/quickstart.md)** - Step-by-step guide to set up and run evaluations
- **[Project Status](project-status.md)** - Current state of Phase 3 completion and Phase 5 execution status

## Implementation Details

- **[Overview](implementation/README.md)** - Project architecture, phases, and scripts
- **[Phase 5 Runner](implementation/phase5-runner.md)** - Implemented workflow contract for `start-swebench.sh` and `run-swebench-batch.sh`
- **[MCP Docker Exec Bridge](implementation/mcp-docker-exec-bridge.md)** - Phase 2 stdlib MCP server contract for container-routed shell execution
- **[Codex Local Bridge](implementation/codex-local-bridge.md)** - Required LiteLLM + vLLM stack for `codex -p local`
- **[Prepare Codex Images](implementation/prepare-codex-images.md)** - Manual utility for pre-injecting codex into SWE-Bench ARM64 images
- **[ARM64 Support](arm64-support/README.md)** - Complete ARM64 implementation guide
- **[ARM64 Quick Start](arm64-support/QUICKSTART.md)** - Quick start for ARM64 evaluations
- **[Code Changes](arm64-support/CHANGES.md)** - Detailed code modifications for ARM64
- **[mvnd Fix](arm64-support/mvnd-fix.md)** - Apache Maven ARM64 binary workaround

## Project Structure

```
docs/
├── README.md              # This file - documentation index
├── project-status.md      # Current project status and runtime state
├── guides/                # User guides and tutorials
│   └── quickstart.md      # Quick start guide
├── implementation/        # Technical implementation docs
│   ├── README.md          # Project overview and scripts
│   ├── codex-local-bridge.md # LiteLLM + vLLM stack for Codex local profile
│   ├── mcp-docker-exec-bridge.md # Phase 2 MCP docker-exec bridge component
│   ├── phase5-runner.md   # Phase 5 single-instance and batch runners
│   └── prepare-codex-images.md  # Manual codex image prep utility
└── arm64-support/         # ARM64-specific documentation
    ├── README.md          # Full ARM64 implementation guide
    ├── QUICKSTART.md      # ARM64 quick start
    ├── CHANGES.md         # Code changes summary
    └── mvnd-fix.md        # Maven ARM64 workaround
```

## Quick Links

### For New Users
Start with the **[Quick Start](guides/quickstart.md)** guide.

### For Current Status
Read **[Project Status](project-status.md)** first to see what is complete, what is closed, and what has been live-tested versus full-run pending.

### For Phase 5 Runner Workflow
Use **[Phase 5 Runner](implementation/phase5-runner.md)** for single-instance and batch prediction contracts, artifact schemas, and failure-code behavior.

### For Codex Local Runtime
Use **[Codex Local Bridge](implementation/codex-local-bridge.md)** for required LiteLLM + vLLM startup order and `codex -p local` smoke tests.

### For ARM64 Users
See **[ARM64 Quick Start](arm64-support/QUICKSTART.md)** for ARM64-specific setup.

### For Developers
Review **[Code Changes](arm64-support/CHANGES.md)** to understand modifications to SWE-bench and SWE-agent.
