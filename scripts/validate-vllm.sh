#!/bin/bash
# validate-vllm.sh — Validate vLLM server is operational
#
# Runs three checks against the vLLM server:
#   1. Health endpoint
#   2. Model list endpoint
#   3. Test chat completion
#
# Usage:
#   ./scripts/validate-vllm.sh                    # Default: http://localhost:8888
#   VLLM_PORT=9000 ./scripts/validate-vllm.sh     # Custom port
#
# Saves all output to results/phase1/

set -e

PORT="${VLLM_PORT:-8888}"
BASE_URL="http://localhost:${PORT}"
RESULTS_DIR="$(dirname "$0")/../results/phase1"
PASS=0
FAIL=0

mkdir -p "$RESULTS_DIR"

echo "=== vLLM Server Validation ==="
echo "Target: ${BASE_URL}"
echo "Results: ${RESULTS_DIR}"
echo ""

# Test 1: Health check
echo "--- Test 1: Health Check ---"
if curl -sf "${BASE_URL}/health" > "$RESULTS_DIR/health.json" 2>&1; then
    echo "PASS: Health endpoint responded"
    cat "$RESULTS_DIR/health.json"
    echo ""
    PASS=$((PASS + 1))
else
    echo "FAIL: Health endpoint unreachable"
    FAIL=$((FAIL + 1))
fi
echo ""

# Test 2: Model list
echo "--- Test 2: Model List ---"
if curl -sf "${BASE_URL}/v1/models" > "$RESULTS_DIR/models.json" 2>&1; then
    echo "PASS: Models endpoint responded"
    cat "$RESULTS_DIR/models.json"
    echo ""
    PASS=$((PASS + 1))
else
    echo "FAIL: Models endpoint unreachable"
    FAIL=$((FAIL + 1))
fi
echo ""

# Test 3: Chat completion
echo "--- Test 3: Chat Completion ---"
if curl -sf "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "Qwen/Qwen3-Coder-Next-FP8",
        "messages": [{"role": "user", "content": "Write a Python hello world"}],
        "temperature": 1.0,
        "top_p": 0.95,
        "max_tokens": 256
    }' > "$RESULTS_DIR/test-completion.json" 2>&1; then
    echo "PASS: Chat completion succeeded"
    cat "$RESULTS_DIR/test-completion.json"
    echo ""
    PASS=$((PASS + 1))
else
    echo "FAIL: Chat completion failed"
    FAIL=$((FAIL + 1))
fi
echo ""

# Summary
echo "=== Validation Summary ==="
echo "Passed: ${PASS}/3"
echo "Failed: ${FAIL}/3"

# Save summary
cat > "$RESULTS_DIR/validation-summary.txt" <<EOF
vLLM Server Validation Summary
==============================
Date: $(date -Iseconds)
Target: ${BASE_URL}
Health: $([ -f "$RESULTS_DIR/health.json" ] && echo "PASS" || echo "FAIL")
Models: $([ -s "$RESULTS_DIR/models.json" ] && echo "PASS" || echo "FAIL")
Completion: $([ -s "$RESULTS_DIR/test-completion.json" ] && echo "PASS" || echo "FAIL")
Result: ${PASS}/3 passed
EOF

if [ "$FAIL" -gt 0 ]; then
    echo "VALIDATION FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
