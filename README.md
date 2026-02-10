# SWE-Bench Evaluation with Qwen3-Coder-Next on DGX Spark

Evaluating [Qwen3-Coder-Next-FP8](https://huggingface.co/Qwen/Qwen3-Coder-Next-FP8) on SWE-Bench Multilingual using native ARM64 containers on NVIDIA DGX Spark.

This project reproduces the [Qwen3-Coder-Next on Spark setup](https://forums.developer.nvidia.com/t/how-to-run-qwen3-coder-next-on-spark/359571) and extends it with ARM64 support for SWE-Bench evaluation.

## Quick Start

See **[docs/](docs/)** for complete documentation including:
- vLLM server setup with the [custom Spark container](https://github.com/eugr/spark-vllm-docker/)
- **[ARM64 support guide](docs/arm64-support/)** for building and running evaluations
- Scripts and configuration

## Project Structure

```
├── config/              # SWE-agent configurations
├── docs/                # Complete documentation
│   └── arm64-support/   # ARM64 implementation guide
├── scripts/             # vLLM server scripts and utilities
└── results/             # Evaluation outputs (gitignored)
    ├── phase1/          # vLLM validation
    └── phase3/          # SWE-Agent evaluation results
```

## ARM64 Support

This project includes patches for running SWE-Bench on ARM64 (aarch64) systems. See:
- **[ARM64 Quick Start](docs/arm64-support/QUICKSTART.md)** - Get started quickly
- **[ARM64 Full Guide](docs/arm64-support/README.md)** - Complete implementation details
- **[Code Changes](docs/arm64-support/CHANGES.md)** - What was modified

**Required forks** (with ARM64 patches):
- [SWE-bench fork](https://github.com/SailorJoe6/SWE-bench) (branch: `arm64-support`)
- [SWE-agent fork](https://github.com/SailorJoe6/SWE-agent) (branch: `arm64-support`)  
