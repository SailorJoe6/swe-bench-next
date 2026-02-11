#!/bin/bash
# launch-vllm.sh — Launch Qwen3-Coder-Next-FP8 on vLLM for SWE-bench evaluation
#
# Prerequisites:
#   - vllm-node Docker image built via spark-vllm-docker
#   - Model weights downloaded to ~/.cache/huggingface/hub/
#
# Usage:
#   ./scripts/launch-vllm.sh              # Launch in foreground (interactive)
#   ./scripts/launch-vllm.sh --daemon     # Launch in background (daemon mode)
#   ./scripts/launch-vllm.sh --stop       # Stop the running server
#   ./scripts/launch-vllm.sh --status     # Check server status
#   ./scripts/launch-vllm.sh --logs       # Tail container logs (daemon mode)
#
# The server listens on port 8888 with OpenAI-compatible API.
# API endpoint: http://localhost:8888/v1
#
# Note: Uses python3 -m vllm.entrypoints.openai.api_server instead of
# "vllm serve" to work around an argparse conflict bug in vLLM 0.15.x.

set -e

SPARK_VLLM_DIR="${SPARK_VLLM_DIR:-$HOME/Code/spark-vllm-docker}"
CONTAINER_NAME="vllm_node"

if [ ! -d "$SPARK_VLLM_DIR" ]; then
    echo "Error: spark-vllm-docker not found at $SPARK_VLLM_DIR"
    echo "Set SPARK_VLLM_DIR to the correct path."
    exit 1
fi

VLLM_ARGS="python3 -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen3-Coder-Next-FP8 \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_xml \
    --gpu-memory-utilization 0.8 \
    --host 0.0.0.0 --port 8888 \
    --load-format fastsafetensors \
    --attention-backend flashinfer \
    --enable-prefix-caching \
    --max-num-seqs 1"

case "${1:-}" in
    --stop)
        cd "$SPARK_VLLM_DIR"
        exec ./launch-cluster.sh stop
        ;;
    --status)
        cd "$SPARK_VLLM_DIR"
        exec ./launch-cluster.sh status
        ;;
    --logs)
        exec docker logs -f "$CONTAINER_NAME"
        ;;
    --daemon)
        # Daemon mode: start container, launch vLLM as background process inside it
        cd "$SPARK_VLLM_DIR"
        ./launch-cluster.sh --solo -d start
        echo "Launching vLLM server inside container..."
        docker exec -d "$CONTAINER_NAME" bash -c "$VLLM_ARGS > /tmp/vllm.log 2>&1"
        echo "vLLM server starting in background."
        echo "Use '$0 --logs' to tail server logs."
        echo "Use '$0 --status' to check container status."
        echo "Use '$0 --stop' to stop the server."
        echo ""
        echo "Waiting for server to be ready..."
        for i in $(seq 1 120); do
            if curl -sf http://localhost:8888/health > /dev/null 2>&1; then
                echo "Server is ready! (took ${i}s)"
                exit 0
            fi
            sleep 1
        done
        echo "Warning: Server did not become ready within 120s."
        echo "Check logs with: $0 --logs"
        exit 1
        ;;
    *)
        # Foreground mode: use launch-cluster.sh exec (blocks until Ctrl+C)
        cd "$SPARK_VLLM_DIR"
        exec ./launch-cluster.sh --solo \
            exec $VLLM_ARGS
        ;;
esac
