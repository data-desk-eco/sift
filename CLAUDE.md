# sift

CLI for investigating subjects in Aleph / OpenAleph, plus a self-driving agent mode (`sift auto`) built on the [`pi`](https://www.npmjs.com/package/@mariozechner/pi) harness. Same command surface for humans and agents.

## Vault & credentials

`~/.sift/` (vault sparseimage, `backend.json` API keys, mounted at `/Volumes/vault-*`) and `~/.aleph/*.passphrase` are blocked by `.claude/hooks/vault-guard.sh` — don't try to work around it. If a task genuinely needs vault contents, ask the user to run the command themselves and paste back what's safe to share. Don't `sift auto` against a real subject from this repo (writes real outputs into the vault).

## Project shape

- Python 3.11+, packaged with hatchling, managed with `uv` (per global preference — never use pip/venv directly here).
- Entry point: `sift.cli:main` → Click commands in `src/sift/commands.py`.
- Vault logic in `src/sift/vault.py` (hdiutil sparseimage + Touch ID gate). Don't refactor this without a clear reason — it mirrors AilephCore/VaultService and a regression here leaks credentials.
- Agent skill file shipped to `pi` lives in `src/sift/share/` (referenced by README as `share/SKILL.md`).
- Targets macOS 13+ on Apple Silicon. Local LLM backend is llama.cpp serving Qwen3.6 35B; hosted backend is any OpenAI-compatible endpoint.

## Working in this repo

- Run/install: `uv tool install --reinstall .` from the repo root, or `uv run sift <cmd>` for ad-hoc.
- The installer (`install.sh`) is intentionally quiet — don't add chatter back in (see commit `ea189a0`).
- Agent voice is deliberately neutral / wire-service (see commit `ef3a85b`); don't loosen it when editing prompts in `share/SKILL.md` or `report.py`.
