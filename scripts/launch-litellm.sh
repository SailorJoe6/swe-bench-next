#!/bin/bash
# launch-litellm.sh — manage LiteLLM proxy for Codex local profile
#
# Usage:
#   ./scripts/launch-litellm.sh            # Start (create container if needed)
#   ./scripts/launch-litellm.sh --stop     # Stop container
#   ./scripts/launch-litellm.sh --status   # Show container + endpoint status
#   ./scripts/launch-litellm.sh --health   # Probe LiteLLM and backend health
#   ./scripts/launch-litellm.sh --logs     # Tail LiteLLM logs

set -euo pipefail

CONTAINER_NAME="${LITELLM_CONTAINER_NAME:-litellm-proxy}"
IMAGE_NAME="${LITELLM_IMAGE:-docker.litellm.ai/berriai/litellm:main-stable}"
CONFIG_PATH="${LITELLM_CONFIG_PATH:-$HOME/litellm/litellm.yaml}"
HOST_PORT="${LITELLM_PORT:-8000}"
CONTAINER_PORT=8000
BASE_URL="http://127.0.0.1:${HOST_PORT}"

usage() {
  cat <<EOF
Usage: $0 [--stop|--status|--health|--logs]

Environment overrides:
  LITELLM_CONTAINER_NAME  (default: litellm-proxy)
  LITELLM_IMAGE           (default: docker.litellm.ai/berriai/litellm:main-stable)
  LITELLM_CONFIG_PATH     (default: \$HOME/litellm/litellm.yaml)
  LITELLM_PORT            (default: 8000)
EOF
}

ensure_config() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "Error: LiteLLM config not found: $CONFIG_PATH" >&2
    exit 1
  fi
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"
}

start_container() {
  ensure_config

  if container_exists; then
    if container_running; then
      echo "LiteLLM container is already running: $CONTAINER_NAME"
      return 0
    fi
    docker start "$CONTAINER_NAME" >/dev/null
    echo "Started existing LiteLLM container: $CONTAINER_NAME"
    return 0
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    --add-host host.docker.internal:host-gateway \
    -v "${CONFIG_PATH}:/app/config.yaml:ro" \
    "$IMAGE_NAME" \
    --config /app/config.yaml \
    --port "$CONTAINER_PORT" >/dev/null

  echo "Created and started LiteLLM container: $CONTAINER_NAME"
}

stop_container() {
  if container_running; then
    docker stop "$CONTAINER_NAME" >/dev/null
    echo "Stopped LiteLLM container: $CONTAINER_NAME"
  else
    echo "LiteLLM container is not running: $CONTAINER_NAME"
  fi
}

status_container() {
  docker ps -a \
    --filter "name=^${CONTAINER_NAME}$" \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

  if container_running; then
    echo
    echo "LiteLLM models endpoint:"
    curl -sS --max-time 8 "${BASE_URL}/v1/models" || true
    echo
  fi
}

health_check() {
  echo "LiteLLM /v1/models:"
  curl -sS --max-time 12 "${BASE_URL}/v1/models"
  echo
  echo
  echo "LiteLLM /health:"
  curl -sS --max-time 12 "${BASE_URL}/health" || true
  echo
}

case "${1:-}" in
  "")
    start_container
    ;;
  --stop)
    stop_container
    ;;
  --status)
    status_container
    ;;
  --health)
    health_check
    ;;
  --logs)
    exec docker logs -f "$CONTAINER_NAME"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac
