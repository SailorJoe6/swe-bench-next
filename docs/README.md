# Documentation Index

Welcome to the SWE-Bench Evaluation project documentation. This index provides quick access to all documentation.

## Getting Started

- **[Quick Start](guides/quickstart.md)** - Step-by-step guide to set up and run evaluations

## Implementation Details

- **[Overview](implementation/README.md)** - Project architecture, phases, and scripts
- **[Phase 5 Runner](implementation/phase5-runner.md)** - Final workflow contract for `start-swebench.sh` and `run-swebench-batch.sh`
- **[Prepare Codex Images](implementation/prepare-codex-images.md)** - Manual utility for pre-injecting codex into SWE-Bench ARM64 images
- **[ARM64 Support](arm64-support/README.md)** - Complete ARM64 implementation guide
- **[ARM64 Quick Start](arm64-support/QUICKSTART.md)** - Quick start for ARM64 evaluations
- **[Code Changes](arm64-support/CHANGES.md)** - Detailed code modifications for ARM64
- **[mvnd Fix](arm64-support/mvnd-fix.md)** - Apache Maven ARM64 binary workaround

## Project Structure

```
docs/
├── README.md              # This file - documentation index
├── guides/                # User guides and tutorials
│   └── quickstart.md      # Quick start guide
├── implementation/        # Technical implementation docs
│   ├── README.md          # Project overview and scripts
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

### For Phase 5 Runner Workflow
Use **[Phase 5 Runner](implementation/phase5-runner.md)** for single-instance and batch prediction contracts, artifact schemas, and failure-code behavior.

### For ARM64 Users
See **[ARM64 Quick Start](arm64-support/QUICKSTART.md)** for ARM64-specific setup.

### For Developers
Review **[Code Changes](arm64-support/CHANGES.md)** to understand modifications to SWE-bench and SWE-agent.
