# Codex Local Bridge (LiteLLM + vLLM)

This project's Codex local profile is a two-hop stack:

1. `codex -p local` talks to LiteLLM on `http://100.106.229.10:8000/v1` using **Responses API** wire format.
2. LiteLLM forwards to local vLLM on `http://host.docker.internal:8888/v1` using **chat completions**.

Without LiteLLM, Codex local can silently fall back to a different provider if your profile is misconfigured or unreachable.

## Required Config Files

- Codex profile: `/home/sailorjoe6/.codex/config.toml`
  - provider `dgx_spark`
  - `wire_api = "responses"`
  - `base_url = "http://100.106.229.10:8000/v1"`
- LiteLLM config: `/home/sailorjoe6/litellm/litellm.yaml`
  - model alias `Qwen3-Coder-Next`
  - backend model `hosted_vllm/Qwen/Qwen3-Coder-Next-FP8`
  - backend `api_base: http://host.docker.internal:8888/v1`
- Container bootstrap config (used by `start-swebench.sh` / `prepare-swebench-codex-images.sh`):
  - `config/codex-container-config.toml` (minimal `profiles.local` + `model_providers.dgx_spark` for in-container `codex exec -p local`)

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
