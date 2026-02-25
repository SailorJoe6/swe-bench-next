#!/bin/bash

# Run SWE-bench test evaluations
# Aggregates predictions from completed instances and runs evaluation

# Parse command line arguments
MAX_WORKERS=1
NAMESPACE="${SWE_BENCH_EVAL_NAMESPACE:-none}"
while [[ $# -gt 0 ]]; do
    case $1 in
        --max_workers)
            MAX_WORKERS="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
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

# Namespace safety note:
# "none" isolates evaluation to local sweb.eval.arm64.* images and avoids stale shared swebench/* tags.
if [[ "$NAMESPACE" != "none" ]]; then
  echo "WARNING: run_test_eval.sh is using namespace '$NAMESPACE' (recommended: none)." >&2
fi

# Run evaluation
nohup python -m swebench.harness.run_evaluation \
  --dataset_name SWE-bench/SWE-bench_Multilingual \
  --predictions_path eval-batch/predictions.jsonl \
  --max_workers $MAX_WORKERS \
  --run_id eval-batch \
  --arch arm64 \
  --namespace "$NAMESPACE" \
  > eval-batch.log 2>&1 &

# Verify it started
sleep 5
ps aux | grep run_evaluation
