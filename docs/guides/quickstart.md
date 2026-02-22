# SWE-Bench Evaluation — Quick Start Guide

This guide covers the quick and dirty about how we set up and run predictions and evaluations for SWE-Bench Multilingual using Qwen3-Coder-Next-FP8 on DGX Spark (ARM64/aarch64).

## Phase 5 Runner Note

If you are using the current Ralph + Codex local workflow (`scripts/start-swebench.sh` and `scripts/run-swebench-batch.sh`), use **[docs/implementation/phase5-runner.md](../implementation/phase5-runner.md)** as the source of truth for CLI usage, output contracts, and failure semantics.

## Prerequisites

### Hardware
- NVIDIA DGX Spark (ARM64/aarch64)
- At least 119GB RAM available

### Software Dependencies

1. **Docker** - Container runtime (comes pre-loaded on the Spark)
   ```bash
   docker --version
   ```

2. **Python 3.11+** with virtual environment support
   ```bash
   python3 --version
   ```

3. **vLLM** via [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker/)

   The specific vLLM container was chosen based on info un [this forum post](https://forums.developer.nvidia.com/t/how-to-run-qwen3-coder-next-on-spark/359571) from the NVidia developer forums.  While Nvidia has their own vLLM container custom designed for the Spark, the official Nvidia container does not support the latest vLLM as of the time of this writing and Qwen3-Coder-Next requires vLLM>=0.15

   ```bash
   git clone https://github.com/eugr/spark-vllm-docker.git ~/Code/spark-vllm-docker
   cd ~/Code/spark-vllm-docker
   # Build the vllm-node Docker image per spark-vllm-docker instructions
   ```

4. **Model Weights** - Download Qwen3-Coder-Next-FP8
   ```bash
   # Model will be downloaded to ~/.cache/huggingface/hub/ on first vLLM launch
   # Or pre-download with:
   huggingface-cli download Qwen/Qwen3-Coder-Next-FP8
   ```

5. **SWE-bench and SWE-agent** (ARM64-patched forks)

   Neither SWE-Bench nor SWE-Agent support ARM64 out of the box.  SailorJoe's forks add ARM64 support to each.  Note that we don't check these out as git submodules, though you could if you want.  All that matters is that you check them out somewhere and install them.  

   ```bash
   git clone https://github.com/SailorJoe6/SWE-bench.git SWE-bench
   git clone https://github.com/SailorJoe6/SWE-agent.git SWE-agent
   cd ~/Code/SWE-bench && pip install -e .
   cd ~/Code/SWE-agent && pip install -e .
   ```

## Quick Start Checklist

### 1. Setup Virtual Environment
```bash
cd YOUR_PROJECT_ROOT
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
```

### 2. Launch vLLM Server

The vLLM server hosts the Qwen3-Coder-Next-FP8 model and provides an OpenAI-compatible API on port 8888.  The settings used in our scripts come mostly from the same [forum post](https://forums.developer.nvidia.com/t/how-to-run-qwen3-coder-next-on-spark/359571) mentinoed earlier, with the single exception that we have chosen to use `--tool-call-parser qwen3_xml` which is slightly more robust than `--tool-call-parser qwen3_coder`.  while SWE-Agent seems to work fine with either tool call parser, we found that other tools (e.g. codex CLI, cline, etc.) work better with the qwen3_xml tool call parser.

```bash
# Launch in daemon mode (background)
./scripts/launch-vllm.sh --daemon

# Check server status
./scripts/launch-vllm.sh --status

# Validate the server (health, models, chat completion)
./scripts/validate-vllm.sh
```

Expected output: All 3 validation tests should pass.

**Note**: First launch may take several minutes as the model loads. The server is ready when `validate-vllm.sh` reports "ALL TESTS PASSED".

### 3. Tag ARM64 Docker Images

SWE-agent expects standard SWE-bench image names. Tag ARM64 images for compatibility:

```bash
./scripts/tag-arm64-images.sh
```

### 4. Run Predictions

Launch the SWE-agent to generate predictions for all 300 test instances:

```bash
cd ~/Code/swebench-eval-next
source venv/bin/activate

# Run predictions (outputs to results/phase3/full-run/)
nohup sweagent run-batch \
  --config config/qwen3-vllm.yaml \
  --output_dir results/phase3/full-run \
  > results/phase3/full-run.log 2>&1 &

# Verify it started
sleep 5
ps aux | grep sweagent
```

### 5. Monitor Progress

Check evaluation progress and estimated completion time:

```bash
./scripts/check-eval-progress.sh
```

**Expected output**:
- Status: RUNNING
- Progress: X / 300 instances (percentage)
- Estimated completion time

**Monitor logs**:
```bash
tail -f results/phase3/full-run.log
```

### 6. Run Test Evaluations

Once predictions are complete (all `.pred` files generated), run evaluations:

```bash
cd ~/Code/swebench-eval-next
source venv/bin/activate

# Aggregate predictions and run evaluation
cd results/phase3
mkdir -p eval-batch
find results/phase3/full-run -name "*.pred" -type f -exec sh -c 'cat "$1"; echo' _ {} \; > eval-batch/predictions.jsonl

# Run evaluation with 1 worker (adjust as needed)
nohup python -m swebench.harness.run_evaluation \
  --dataset_name SWE-bench/SWE-bench_Multilingual \
  --predictions_path eval-batch/predictions.jsonl \
  --max_workers 1 \
  --run_id eval-batch \
  --arch arm64 \
  > eval-batch.log 2>&1 &

# Monitor
tail -f eval-batch.log
```

**Alternative**: Use the provided script:
```bash
./scripts/run_test_eval.sh --max_workers 1
```

## Troubleshooting

### vLLM Server Issues

**Server doesn't start**:
```bash
# Check container status
./scripts/launch-vllm.sh --status

# View container logs
./scripts/launch-vllm.sh --logs

# Stop and restart
./scripts/launch-vllm.sh --stop
./scripts/launch-vllm.sh --daemon
```

**Validation fails**:
- Verify Docker is running: `docker ps`
- Check model weights exist: `ls ~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-FP8/`
- Ensure spark-vllm-docker is properly configured

### SWE-agent Issues

**Agent doesn't start**:
```bash
# Verify venv is activated
which sweagent

# Check logs
tail -f results/phase3/full-run.log
```

**Agent errors on specific instances**:
- Check instance-specific logs in `results/phase3/full-run/<instance-name>/`
- Review `.traj` files with: `./scripts/view-traj.sh <traj-file>`

**Speed optimization**:
- Reduce `total_cost_limit` in `config/qwen3-vllm.yaml` if running out of budget
- Increase `--max_workers` in `run_evaluation` if evaluation is slow

### Common Issues

| Issue | Solution |
|-------|----------|
| Model loading takes too long | Use `--daemon` mode; first load can take 5-10 minutes |
| Out of memory errors | Reduce `--gpu-memory-utilization` in `launch-vllm.sh` |
| Predictions stuck | Check `check-eval-progress.sh` for current instance; review logs |
| Evaluation fails on instance | Check `eval-batch.log` for specific errors |

## Directory Structure

```
results/
├── phase3/
│   ├── full-run/           # SWE-agent predictions
│   │   ├── <instance-1>/
│   │   ├── <instance-2>/
│   │   └── ...
│   ├── eval-batch/         # Test evaluation results
│   │   ├── predictions.jsonl
│   │   └── eval-batch.log
│   └── full-run.log        # SWE-agent log
```

## Key Files

| File | Purpose |
|------|---------|
| `config/qwen3-vllm.yaml` | SWE-agent configuration for Qwen3-Coder-Next-FP8 |
| `scripts/launch-vllm.sh` | Launch/stop/status for vLLM server |
| `scripts/validate-vllm.sh` | Validate vLLM server health |
| `scripts/check-eval-progress.sh` | Monitor evaluation progress |
| `scripts/run_test_eval.sh` | Run test evaluations |
| `scripts/view-traj.sh` | View trajectory files |
| `scripts/tag-arm64-images.sh` | Tag ARM64 Docker images |

## Next Steps

After completing evaluations:
1. Review results in `results/phase3/full-run/`
2. Check evaluation metrics in `results/phase3/eval-batch/`
3. Analyze failed instances for debugging
4. Generate final reports

For detailed ARM64 implementation details, see [docs/arm64-support/README.md](arm64-support/README.md).
