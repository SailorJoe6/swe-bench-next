# SWE-Bench Evaluation — Documentation Index

This directory contains documentation for the SWE-Bench Multilingual evaluation project using Qwen3-Coder-Next-FP8 on DGX Spark.

## Project Overview

The project evaluates Qwen3-Coder-Next-FP8 on [SWE-Bench Multilingual](https://github.com/SWE-bench/SWE-bench) using the SWE-Agent harness with native ARM64 container support.

### Evaluation Phases

1. **Phase 1: vLLM Setup** ✅ — Deploy Qwen3-Coder-Next-FP8 using [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker/)
2. **Phase 2: Default Harness** ⏭️ — Skipped (incompatible with custom vLLM endpoints)
3. **Phase 3: SWE-Agent** ⏳ — Agentic evaluation with ARM64 containers (in progress)
4. **Phase 4: mini-SWE-agent** 🔮 — Optional lightweight agent (pending Phase 3)

All evaluations run on a single DGX Spark (ARM64/aarch64) with native ARM64 Docker images.

### ARM64 Support

This project includes comprehensive ARM64 support for SWE-Bench evaluation:
- Native ARM64 Docker images (no QEMU emulation)
- Chrome → Chromium substitution for JavaScript projects
- Architecture-specific package downloads
- **295/377 instances** successfully built (78% success rate)

**See [arm64-support/](arm64-support/) for complete ARM64 documentation.**

## Directory Layout

```
swebench-eval-next/
├── config/             # SWE-agent configuration files
├── docs/               # This documentation directory
│   └── arm64-support/  # ARM64 implementation guide
├── scripts/            # vLLM server scripts and utilities
├── results/            # Evaluation outputs (gitignored)
│   ├── phase1/         # vLLM validation outputs and logs
│   ├── phase2/         # (skipped)
│   ├── phase3/         # SWE-Agent harness results and JSON predictions
│   └── phase4/         # mini-SWE-agent harness results (optional)
└── ralph/              # AI-assisted development workflow (separate submodule)
```

## Scripts

| Script | Description | Phase |
|--------|-------------|-------|
| `scripts/launch-vllm.sh` | Launch/stop/status for the Qwen3-Coder-Next-FP8 vLLM server | 1 |
| `scripts/validate-vllm.sh` | Validate vLLM server health, models, and chat completion | 1 |

### `scripts/launch-vllm.sh`

Wraps `spark-vllm-docker/launch-cluster.sh` with the exact vLLM configuration for SWE-bench evaluation.

**Prerequisites**:
- `vllm-node` Docker image built via `spark-vllm-docker`
- Model weights at `~/.cache/huggingface/hub/`
- `SPARK_VLLM_DIR` env var (defaults to `~/Code/spark-vllm-docker`)

**Usage**:
```bash
./scripts/launch-vllm.sh              # Launch in foreground
./scripts/launch-vllm.sh --daemon     # Launch in background (waits for server ready)
./scripts/launch-vllm.sh --stop       # Stop the server
./scripts/launch-vllm.sh --status     # Check container status
./scripts/launch-vllm.sh --logs       # Tail server logs (daemon mode)
```

**Configuration**: Port 8888, `--max-num-seqs 1` (single-request constraint for DGX Spark), `--gpu-memory-utilization 0.8`, flashinfer attention backend, prefix caching enabled, fastsafetensors loading.

**Note**: Uses `python3 -m vllm.entrypoints.openai.api_server` instead of `vllm serve` to work around an argparse conflict bug in vLLM 0.15.x.

### `scripts/validate-vllm.sh`

Runs three validation checks against the vLLM server and saves results to `results/phase1/`.

**Usage**:
```bash
./scripts/validate-vllm.sh                    # Default: http://localhost:8888
VLLM_PORT=9000 ./scripts/validate-vllm.sh     # Custom port
```

**Checks**: Health endpoint, model list, test chat completion. Outputs JSON responses and a summary to `results/phase1/`.

## Documentation Sections

- **[arm64-support/](arm64-support/)** — Complete ARM64 implementation guide
  - [QUICKSTART.md](arm64-support/QUICKSTART.md) — Quick start guide
  - [README.md](arm64-support/README.md) — Full implementation details
  - [CHANGES.md](arm64-support/CHANGES.md) — Code modifications

## Key References

### vLLM & Model Setup
- [NVIDIA Forum Post — Qwen3-Coder-Next on Spark](https://forums.developer.nvidia.com/t/how-to-run-qwen3-coder-next-on-spark/359571)
- [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker/) — Custom vLLM container for DGX Spark
- [Qwen3-Coder-Next-FP8](https://huggingface.co/Qwen/Qwen3-Coder-Next-FP8) — Model weights on HuggingFace

### SWE-Bench Frameworks
- [SWE-Bench](https://github.com/SWE-bench/SWE-bench) — Evaluation harness
- [SWE-Agent](https://github.com/SWE-agent/SWE-agent) — Agentic framework
- [mini-SWE-agent](https://github.com/SWE-agent/mini-SWE-agent) — Lightweight agent

### ARM64-Patched Forks
- [SWE-bench fork](https://github.com/SailorJoe6/SWE-bench) (branch: `arm64-support`) — ARM64 Docker image support
- [SWE-agent fork](https://github.com/SailorJoe6/SWE-agent) (branch: `arm64-support`) — ARM64 architecture parameter

## Environment

- **Hardware**: DGX Spark, NVIDIA GB10, 119GB RAM, 20 CPUs
- **Container Runtime**: Docker
- **Model**: Qwen3-Coder-Next-FP8 (80B params, FP8 quantization)
- **Serving**: vLLM via spark-vllm-docker (`--max-num-seqs 1` for single-request constraint)
