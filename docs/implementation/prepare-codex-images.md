# Prepare Codex Images

This page documents `scripts/prepare-swebench-codex-images.sh`, the manual Phase 4 utility for pre-injecting codex into SWE-Bench ARM64 instance images.

## Purpose

Use this utility when you want codex already present in images before running:

- `scripts/start-swebench.sh`
- `scripts/run-swebench-batch.sh`

It is optional and never auto-invoked by runtime scripts.

## What It Does

For each selected image, the script:

1. validates the image exists,
2. creates a temporary container,
3. copies codex binary/config into the container,
4. commits the container back to the same tag,
5. verifies `codex` is available in the updated image.

Tag overwrite behavior is in-place:

- `sweb.eval.arm64.<instance_id>:latest` is committed back to itself.

## Bootstrap Sources

Defaults:

- binary: `/home/sailorjoe6/.cargo/bin/codex`
- config: `/home/sailorjoe6/.codex/config.toml`

Overrides:

- `CODEX_BOOTSTRAP_BIN_PATH`
- `CODEX_BOOTSTRAP_CONFIG_PATH`

## Target Selection

Provide at least one selector:

- `--instance-id <id>` (repeatable)
- `--instance-file <path>` (`txt`, `json`, or `jsonl`)
- `--image <image-ref>` (repeatable)
- `--all-local-images` (targets local `sweb.eval.arm64.*:latest`)

Resolved targets are deduplicated and processed in lexicographic order.

## Examples

```bash
# Single instance image
scripts/prepare-swebench-codex-images.sh --instance-id django__django-10097

# Subset file + one explicit image
scripts/prepare-swebench-codex-images.sh \
  --instance-file ./instance_ids.txt \
  --image sweb.eval.arm64.repo__custom-1:latest

# Preflight target resolution only
scripts/prepare-swebench-codex-images.sh --all-local-images --dry-run
```

## Failure Behavior

- The script continues across targets and reports a final summary.
- Exit code is `1` if any target fails.
- Exit code is `0` only when all targets are prepared successfully.
