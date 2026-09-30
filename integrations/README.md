# Integrations

Provider entries and configuration snippets for tools commonly run alongside LM Switcher.

## OrcaRouter (optional cloud provider)

[OrcaRouter](https://www.orcarouter.ai) puts 200+ cloud models (DeepSeek, GLM, Kimi, Qwen, Claude, GPT, Gemini, ...) behind one OpenAI-compatible endpoint — handy when you want a cloud model without touching any of your local-model workflows.

- Base URL: `https://api.orcarouter.ai/v1`
- Auth: `Bearer $ORCA_KEY`
- Models: any id from `GET /v1/models`, e.g. `deepseek/deepseek-v4.1-flash`, `z-ai/glm-5.3-flash`, `moonshotai/kimi-k3`, or `orcarouter/auto` for automatic routing
- Get a key: https://www.orcarouter.ai/register

See [`orcarouter.toml`](./orcarouter.toml) for a ready-to-copy provider entry (Codex CLI format) plus a generic OpenAI-compatible snippet.
