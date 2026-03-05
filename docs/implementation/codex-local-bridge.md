# Codex Local Bridge (LiteLLM + vLLM)

This project's Codex local profile is a two-hop stack:

1. `codex -p local` talks to LiteLLM on `http://100.106.229.10:8000/v1` using **Responses API** wire format.
2. LiteLLM forwards to local vLLM on `http://host.docker.internal:8888/v1` using **chat completions**.

Without LiteLLM, Codex local can silently fall back to a different provider if your profile is misconfigured or unreachable.

## Required Config Files

- Runner Codex home config (used by `start-swebench.sh`):
  - `config/codex-home/config.toml`
  - provider `dgx_spark`
  - `wire_api = "responses"`
  - `base_url = "http://100.106.229.10:8000/v1"`
  - `model_catalog_json = "/home/sailorjoe6/Code/swebench-eval-next/config/codex-home/qwen3-model-catalog.json"`
  - `model_instructions_file = "/home/sailorjoe6/Code/swebench-eval-next/config/codex-home/prompt.md"`
  - selected by setting `CODEX_HOME` to `config/codex-home` (default behavior in `start-swebench.sh`)
- Optional personal Codex profile for manual CLI use:
  - `/home/sailorjoe6/.codex/config.toml`
- LiteLLM config: `/home/sailorjoe6/litellm/litellm.yaml`
  - model alias `Qwen3-Coder-Next`
  - backend model `hosted_vllm/Qwen/Qwen3-Coder-Next-FP8`
  - backend `api_base: http://host.docker.internal:8888/v1`
- Container bootstrap config (used by `start-swebench.sh` / `prepare-swebench-codex-images.sh`):
  - `config/codex-container-config.toml` (minimal `profiles.local` + `model_providers.dgx_spark` for in-container `codex exec -p local`)

## Repo-Local Custom Codex Base Instructions

This repository uses a custom base-instructions file for `profiles.local`:

- Source template copied from Codex CLI core prompt:
  - `/home/sailorjoe6/Code/codex-ultimate/codex-rs/core/prompt.md`
- Repo-local authoritative copy used at runtime:
  - `config/codex-home/prompt.md`
- Profile binding (authoritative override):
  - `config/codex-home/config.toml`
  - `model_catalog_json = "/home/sailorjoe6/Code/swebench-eval-next/config/codex-home/qwen3-model-catalog.json"`
  - `model_instructions_file = "/home/sailorjoe6/Code/swebench-eval-next/config/codex-home/prompt.md"`
- Repo-local model catalog used by `model_catalog_json`:
  - `config/codex-home/qwen3-model-catalog.json`
  - defines local metadata/capabilities for Qwen3 model slugs (context window, tool/shell behavior hints)

Surgical local customization applied in `config/codex-home/prompt.md`:

- Base capabilities line is replaced so Codex is told to use only:
  - `swebench_docker_exec.mcp-docker-exec({"command":"..."})`
- It explicitly forbids `apply_patch`.
- Intent: prevent phase stalls caused by repeated unsupported `apply_patch` calls in MCP-only runtime sessions.

Important runtime note:

- This override applies to new Codex sessions.
- If a long-running prediction pass is already in-flight, stop and restart that run so new sessions pick up the updated base instructions.

## Start Order

```bash
cd ~/Code/swebench-eval-next

# 1) Start vLLM backend (Qwen on GPU)
./scripts/launch-vllm.sh --daemon
./scripts/validate-vllm.sh

# 2) Start LiteLLM bridge
./scripts/launch-litellm.sh
./scripts/launch-litellm.sh --health
```

## Codex Smoke Test (Mandatory Before Batch)

```bash
CODEX_HOME="$(pwd)/config/codex-home" \
codex exec -p local --dangerously-bypass-approvals-and-sandbox \
  "Respond with exactly: CODEX_LOCAL_BRIDGE_OK"
```

Expected:

- stdout contains `CODEX_LOCAL_BRIDGE_OK`
- Codex header shows `provider: dgx_spark`
- LiteLLM logs show `POST /v1/responses`:

```bash
docker logs --tail 50 litellm-proxy
```

Optional verify for custom base instructions:

```bash
rg -n "model_instructions_file|model_catalog_json" config/codex-home/config.toml
jq '.models[] | {slug, context_window, shell_type, supports_parallel_tool_calls, input_modalities}' config/codex-home/qwen3-model-catalog.json
sed -n '1,12p' config/codex-home/prompt.md
```

## Operational Checks

```bash
# vLLM models endpoint
curl -sS http://127.0.0.1:8888/v1/models | jq .

# LiteLLM exposed models
curl -sS http://127.0.0.1:8000/v1/models | jq .
```

## Stop

```bash
./scripts/launch-litellm.sh --stop
./scripts/launch-vllm.sh --stop
```
