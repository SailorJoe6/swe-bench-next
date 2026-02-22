#!/usr/bin/env bash
set -euo pipefail

IMAGE_REPO_PREFIX="sweb.eval.arm64"
CODEX_BOOTSTRAP_BIN_PATH="${CODEX_BOOTSTRAP_BIN_PATH:-/home/sailorjoe6/.cargo/bin/codex}"
CODEX_BOOTSTRAP_CONFIG_PATH="${CODEX_BOOTSTRAP_CONFIG_PATH:-/home/sailorjoe6/.codex/config.toml}"

INSTANCE_FILE=""
INCLUDE_ALL_LOCAL_IMAGES=0
DRY_RUN=0

declare -a INSTANCE_IDS=()
declare -a DIRECT_IMAGE_REFS=()

usage() {
  cat <<'USAGE'
Usage: scripts/prepare-swebench-codex-images.sh [options]

Manual utility to pre-inject codex binary/config into SWE-Bench ARM64 images.
This script is optional and is not auto-invoked by runtime runners.

Target selectors (provide at least one):
  --instance-id <id>       Add one instance image target (repeatable)
  --instance-file <path>   Add instance IDs from file (txt/json/jsonl)
  --image <image-ref>      Add explicit image ref target (repeatable)
  --all-local-images       Target all local sweb.eval.arm64.*:latest images

Options:
  --dry-run                Print resolved targets without mutating images
  -h, --help               Show this help message

Environment overrides:
  CODEX_BOOTSTRAP_BIN_PATH     (default: /home/sailorjoe6/.cargo/bin/codex)
  CODEX_BOOTSTRAP_CONFIG_PATH  (default: /home/sailorjoe6/.codex/config.toml)
USAGE
}

error() {
  echo "Error: $*" >&2
}

ensure_docker_available() {
  if ! command -v docker >/dev/null 2>&1; then
    error "docker command not found on PATH"
    return 1
  fi
}

instance_image_ref() {
  local instance_id="$1"
  printf '%s.%s:latest\n' "$IMAGE_REPO_PREFIX" "$instance_id"
}

collect_instance_ids_from_file() {
  local instance_file="$1"
  python3 - "$instance_file" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise RuntimeError(f"--instance-file path does not exist: {path}")


def normalize(values):
    ids = []
    for value in values:
        if isinstance(value, str):
            trimmed = value.strip()
            if trimmed:
                ids.append(trimmed)
    return sorted(set(ids))


def records_to_ids(records):
    ids = []
    for record in records:
        if isinstance(record, str):
            ids.append(record)
            continue
        if isinstance(record, dict):
            instance_id = record.get("instance_id")
            if isinstance(instance_id, str) and instance_id.strip():
                ids.append(instance_id)
                continue
            raise RuntimeError(f"record in {path} is missing non-empty instance_id")
        raise RuntimeError(f"unsupported record type in {path}: {type(record).__name__}")
    return normalize(ids)


text = path.read_text(encoding="utf-8")
suffix = path.suffix.lower()
records = None

if suffix == ".jsonl":
    rows = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        row = line.strip()
        if not row:
            continue
        try:
            rows.append(json.loads(row))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"invalid JSONL in {path} at line {line_number}: {exc.msg}") from exc
    records = rows
elif suffix == ".json":
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON in {path}: {exc.msg}") from exc
    if isinstance(data, list):
        records = data
    elif isinstance(data, dict):
        if isinstance(data.get("instances"), list):
            records = data["instances"]
        else:
            records = [data]
    else:
        raise RuntimeError(f"unsupported JSON structure in {path}; expected object or array")

if records is None:
    values = []
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        values.append(stripped)
    ids = normalize(values)
else:
    ids = records_to_ids(records)

for instance_id in ids:
    print(instance_id)
PY
}

collect_all_local_images() {
  docker images --format '{{.Repository}}:{{.Tag}}' \
    | awk -v prefix="${IMAGE_REPO_PREFIX}." 'index($0, prefix) == 1 && $0 ~ /:latest$/ {print $0}' \
    | sort -u
}

require_bootstrap_sources() {
  if [[ ! -x "$CODEX_BOOTSTRAP_BIN_PATH" ]]; then
    error "codex bootstrap binary is missing or not executable: $CODEX_BOOTSTRAP_BIN_PATH"
    return 1
  fi

  if [[ ! -f "$CODEX_BOOTSTRAP_CONFIG_PATH" ]]; then
    error "codex bootstrap config is missing: $CODEX_BOOTSTRAP_CONFIG_PATH"
    return 1
  fi
}

cleanup_container() {
  local container_id="$1"
  if [[ -n "$container_id" ]]; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
}

inject_codex_into_image() {
  local image_ref="$1"
  local container_id=""

  if ! docker image inspect "$image_ref" >/dev/null 2>&1; then
    error "image not found: $image_ref"
    return 1
  fi

  if ! container_id="$(docker create --entrypoint /bin/sh "$image_ref" -lc 'while true; do sleep 3600; done')"; then
    error "failed to create bootstrap container from image: $image_ref"
    return 1
  fi

  if ! docker start "$container_id" >/dev/null; then
    error "failed to start bootstrap container: $container_id"
    cleanup_container "$container_id"
    return 1
  fi

  if ! docker exec "$container_id" /bin/sh -lc "mkdir -p /usr/local/bin /root/.codex /home/sailorjoe6/.codex"; then
    error "failed to prepare target directories in container: $container_id"
    cleanup_container "$container_id"
    return 1
  fi

  if ! docker cp "$CODEX_BOOTSTRAP_BIN_PATH" "$container_id:/usr/local/bin/codex"; then
    error "failed to copy codex binary into container: $container_id"
    cleanup_container "$container_id"
    return 1
  fi

  if ! docker cp "$CODEX_BOOTSTRAP_CONFIG_PATH" "$container_id:/root/.codex/config.toml"; then
    error "failed to copy codex config into /root/.codex for container: $container_id"
    cleanup_container "$container_id"
    return 1
  fi

  if ! docker cp "$CODEX_BOOTSTRAP_CONFIG_PATH" "$container_id:/home/sailorjoe6/.codex/config.toml"; then
    error "failed to copy codex config into /home/sailorjoe6/.codex for container: $container_id"
    cleanup_container "$container_id"
    return 1
  fi

  if ! docker exec "$container_id" /bin/sh -lc "chmod +x /usr/local/bin/codex"; then
    error "failed to mark codex executable in container: $container_id"
    cleanup_container "$container_id"
    return 1
  fi

  if ! docker commit "$container_id" "$image_ref" >/dev/null; then
    error "failed to commit bootstrapped image: $image_ref"
    cleanup_container "$container_id"
    return 1
  fi

  cleanup_container "$container_id"

  if ! docker run --rm --entrypoint /bin/sh "$image_ref" -lc "command -v codex >/dev/null 2>&1"; then
    error "codex verification failed after bootstrap commit: $image_ref"
    return 1
  fi

  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id)
      [[ $# -ge 2 ]] || { error "--instance-id requires a value"; exit 2; }
      INSTANCE_IDS+=("$2")
      shift 2
      ;;
    --instance-file)
      [[ $# -ge 2 ]] || { error "--instance-file requires a value"; exit 2; }
      INSTANCE_FILE="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || { error "--image requires a value"; exit 2; }
      DIRECT_IMAGE_REFS+=("$2")
      shift 2
      ;;
    --all-local-images)
      INCLUDE_ALL_LOCAL_IMAGES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ${#INSTANCE_IDS[@]} -eq 0 && -z "$INSTANCE_FILE" && ${#DIRECT_IMAGE_REFS[@]} -eq 0 && "$INCLUDE_ALL_LOCAL_IMAGES" -eq 0 ]]; then
  error "at least one target selector is required (--instance-id/--instance-file/--image/--all-local-images)"
  exit 2
fi

if [[ -n "$INSTANCE_FILE" && ! -f "$INSTANCE_FILE" ]]; then
  error "--instance-file does not exist: $INSTANCE_FILE"
  exit 1
fi

if ! ensure_docker_available; then
  exit 1
fi

if [[ -n "$INSTANCE_FILE" ]]; then
  if ! mapfile -t FILE_INSTANCE_IDS < <(collect_instance_ids_from_file "$INSTANCE_FILE"); then
    error "failed to resolve instance IDs from --instance-file"
    exit 1
  fi
  INSTANCE_IDS+=("${FILE_INSTANCE_IDS[@]}")
fi

declare -a TARGET_IMAGE_REFS=()

if [[ ${#DIRECT_IMAGE_REFS[@]} -gt 0 ]]; then
  TARGET_IMAGE_REFS+=("${DIRECT_IMAGE_REFS[@]}")
fi

if [[ ${#INSTANCE_IDS[@]} -gt 0 ]]; then
  for instance_id in "${INSTANCE_IDS[@]}"; do
    TARGET_IMAGE_REFS+=("$(instance_image_ref "$instance_id")")
  done
fi

if [[ "$INCLUDE_ALL_LOCAL_IMAGES" -eq 1 ]]; then
  if ! mapfile -t ALL_LOCAL_IMAGE_REFS < <(collect_all_local_images); then
    error "failed to resolve local image targets"
    exit 1
  fi
  TARGET_IMAGE_REFS+=("${ALL_LOCAL_IMAGE_REFS[@]}")
fi

if ! mapfile -t TARGET_IMAGE_REFS < <(printf '%s\n' "${TARGET_IMAGE_REFS[@]}" | awk 'NF {print}' | sort -u); then
  error "failed to normalize target image refs"
  exit 1
fi

if [[ ${#TARGET_IMAGE_REFS[@]} -eq 0 ]]; then
  error "no image targets resolved from provided selectors"
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run target images (${#TARGET_IMAGE_REFS[@]}):"
  printf '  %s\n' "${TARGET_IMAGE_REFS[@]}"
  exit 0
fi

if ! require_bootstrap_sources; then
  exit 1
fi

SUCCESS_COUNT=0
FAILED_COUNT=0
declare -a FAILED_IMAGES=()

for image_ref in "${TARGET_IMAGE_REFS[@]}"; do
  echo "Preparing image: $image_ref"
  if inject_codex_into_image "$image_ref"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    echo "Prepared image: $image_ref"
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_IMAGES+=("$image_ref")
    echo "Failed image: $image_ref" >&2
  fi
done

echo "prepare-swebench-codex-images summary: total=${#TARGET_IMAGE_REFS[@]} success=${SUCCESS_COUNT} failed=${FAILED_COUNT}"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  printf 'Failed targets:\n' >&2
  printf '  %s\n' "${FAILED_IMAGES[@]}" >&2
  exit 1
fi

exit 0
