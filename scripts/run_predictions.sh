#!/bin/bash

# Run SWE-agent harness based predictions

cd ~/Code/swebench-eval-next
source venv/bin/activate

cd ~/Code/swebench-eval-next
source venv/bin/activate

nohup sweagent run-batch \
  --config config/qwen3-vllm.yaml \
  --output_dir results/phase3/full-run \
  > results/phase3/full-run.log 2>&1 &

# Verify it started (wait a few seconds)
sleep 5
ps aux | grep sweagent
