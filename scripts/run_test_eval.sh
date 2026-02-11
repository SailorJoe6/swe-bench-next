#!/bin/bash

# Run SWE-bench test evaluations
# Aggregates predictions from completed instances and runs evaluation

# Parse command line arguments
MAX_WORKERS=1
while [[ $# -gt 0 ]]; do
    case $1 in
        --max_workers)
            MAX_WORKERS="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

cd ~/Code/swebench-eval-next
source venv/bin/activate

# Switch to results/phase3 so logs go to results/phase3/logs/run_evaluation/
cd results/phase3

# Aggregate predictions from .pred files (add newline after each JSON object)
mkdir -p eval-batch
find full-run -name "*.pred" -type f -exec sh -c 'cat "$1"; echo' _ {} \; > eval-batch/predictions.jsonl

# Run evaluation
nohup python -m swebench.harness.run_evaluation \
  --dataset_name SWE-bench/SWE-bench_Multilingual \
  --predictions_path results/phase3/eval-batch-N/predictions.jsonl \
  --max_workers $MAX_WORKERS \
  --run_id eval-batch \
  --arch arm64 \
  > eval-batch.log 2>&1 &

# Verify it started
sleep 5
ps aux | grep run_evaluation
