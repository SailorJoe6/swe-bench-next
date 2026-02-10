# SWE-Bench Evaluation — Documentation Index

This directory contains documentation for the SWE-Bench Multilingual evaluation project using Qwen3-Coder-Next-FP8 on DGX Spark.

## Project Overview

The project evaluates Qwen3-Coder-Next-FP8 on [SWE-Bench Multilingual](https://github.com/SWE-bench/SWE-bench) using three harness configurations:

1. **Default SWE-Bench harness** — direct inference pipeline (`swebench.inference.run_api`)
2. **SWE-Agent harness** — agentic loop with tool-use scaffolding
3. **mini-SWE-agent harness** (optional) — lightweight agent for comparison

All evaluations target the full SWE-Bench Multilingual test slice (~300 instances) running against a local vLLM server on a single DGX Spark.

## Directory Layout

```
swebench-eval-next/
├── docs/               # This documentation directory
├── scripts/            # Reusable scripts (server launch, reports, etc.)
├── results/
│   ├── phase1/         # vLLM validation outputs and logs
│   ├── phase2/         # SWE-Bench default harness results
│   ├── phase3/         # SWE-Agent harness results and JSON predictions
│   └── phase4/         # mini-SWE-agent harness results (optional)
└── ralph/              # AI-assisted development workflow (separate repo)
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

## Key References

- [NVIDIA Forum Post — Qwen3-Coder-Next on Spark](https://forums.developer.nvidia.com/t/how-to-run-qwen3-coder-next-on-spark/359571)
- [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker/) — custom vLLM container for DGX Spark
- [Qwen3-Coder-Next-FP8 on HuggingFace](https://huggingface.co/Qwen/Qwen3-Coder-Next-FP8)
- [SWE-Bench](https://github.com/SWE-bench/SWE-bench)
- [SWE-Agent](https://github.com/SWE-agent/SWE-agent)
- [mini-SWE-agent](https://github.com/SWE-agent/mini-SWE-agent)

## Environment

- **Hardware**: DGX Spark, NVIDIA GB10, 119GB RAM, 20 CPUs
- **Container Runtime**: Docker
- **Model**: Qwen3-Coder-Next-FP8 (80B params, FP8 quantization)
- **Serving**: vLLM via spark-vllm-docker (`--max-num-seqs 1` for single-request constraint)
