"""LLM backend — the on-disk config (~/.sift/backend.json), pi's
provider config (~/.sift/pi/), and the local llama.cpp daemon
lifecycle. The hosted path is config-only; the local path additionally
manages a llama-server process started with `start_new_session=True`
so it survives the parent's exit, with a pidfile and a polling
health check."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

import click
import requests

from .errors import CommandError

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_LOCAL_PORT = 1234

# Recommended local model — Qwen3.6 35B A3B (MoE; ~3B active), unsloth
# UD-Q2_K_XL quant. ~12.3 GB on disk, fits on a 24 GB Mac alongside a
# 256k context window. Both llama-server and pi need to know the same
# size — pi uses LOCAL_CONTEXT_WINDOW to decide when to compact, and
# defaults to 128k if the model entry doesn't tell it otherwise.
DEFAULT_MODEL_REPO = "unsloth/Qwen3.6-35B-A3B-GGUF"
DEFAULT_MODEL_FILE = "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf"
DEFAULT_MODEL_NAME = "qwen3.6-35b-a3b"
DEFAULT_MODEL_DISPLAY = "Qwen3.6 35B A3B (local)"
LOCAL_CONTEXT_WINDOW = 262144

SIFT_HOME = Path.home() / ".sift"


# ---------------------------------------------------------------------------
# Config file — backend.json
# ---------------------------------------------------------------------------

def backend_path() -> Path:
    return SIFT_HOME / "backend.json"


def read_config() -> dict[str, Any] | None:
    try:
        return json.loads(backend_path().read_text())
    except FileNotFoundError:
        return None


def _write_config(data: dict[str, Any]) -> None:
    path = backend_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")
    path.chmod(0o600)


def write_local(model_file: str = DEFAULT_MODEL_FILE,
                model_name: str = DEFAULT_MODEL_NAME,
                port: int = DEFAULT_LOCAL_PORT) -> None:
    _write_config({
        "kind": "local",
        "model_file": model_file,
        "model_name": model_name,
        "port": port,
    })


def write_hosted(base_url: str, api_key: str, model_name: str) -> None:
    _write_config({
        "kind": "hosted",
        "base_url": base_url,
        "api_key": api_key,
        "model_name": model_name,
    })


def configure_pi() -> None:
    """Write pi/models.json and pi/settings.json so pi talks to our backend.
    Idempotent — overwritten every run so the local port stays in sync."""
    config = read_config()
    if not config:
        raise CommandError(
            "no backend configured",
            "run 'sift init' or 'sift backend local|hosted'",
        )
    if config["kind"] == "local":
        port = config.get("port", DEFAULT_LOCAL_PORT)
        base_url = f"http://127.0.0.1:{port}/v1"
        api_key = "sift-local"
        display = DEFAULT_MODEL_DISPLAY
    else:
        base_url = config["base_url"]
        api_key = config.get("api_key", "")
        display = config["model_name"]
    model = config["model_name"]
    pi_dir = SIFT_HOME / "pi"
    pi_dir.mkdir(parents=True, exist_ok=True)
    (pi_dir / "models.json").write_text(json.dumps({
        "providers": {"sift": {
            "baseUrl": base_url,
            "api": "openai-completions",
            "apiKey": api_key,
            "compat": {
                "supportsDeveloperRole": False,
                "supportsReasoningEffort": False,
            },
            "models": [{
                "id": model, "name": display,
                # Pi defaults to 128k if absent — match what llama-server is
                # actually serving so it doesn't compact prematurely. For
                # hosted backends we leave this off and let pi pick whatever
                # the provider/model advertises.
                **({"contextWindow": LOCAL_CONTEXT_WINDOW}
                   if config["kind"] == "local" else {}),
            }],
        }},
    }, indent=2) + "\n")
    (pi_dir / "settings.json").write_text(json.dumps({
        "defaultProvider": "sift",
        "defaultModel": model,
    }, indent=2) + "\n")


# ---------------------------------------------------------------------------
# Local llama-server lifecycle
# ---------------------------------------------------------------------------

def _local_port() -> int:
    config = read_config() or {}
    return int(config.get("port", DEFAULT_LOCAL_PORT))


def health_check(port: int) -> bool:
    try:
        requests.get(f"http://127.0.0.1:{port}/v1/models", timeout=1)
        return True
    except requests.RequestException:
        return False


def start_local() -> None:
    """Spawn llama-server detached, write pidfile, poll until ready."""
    port = _local_port()
    if health_check(port):
        click.echo(f"[server]   llama-server already up on :{port}")
        return
    model_path = SIFT_HOME / "models" / DEFAULT_MODEL_FILE
    if not model_path.exists():
        raise CommandError(
            f"model not found at {model_path}",
            "run 'sift init' to download it",
        )
    log_path = SIFT_HOME / "llama-server.log"
    pid_path = SIFT_HOME / "llama-server.pid"
    click.echo(f"[server]   starting llama-server on :{port} (logs: {log_path})")
    log = open(log_path, "ab")
    proc = subprocess.Popen(
        [
            "llama-server",
            "--model", str(model_path),
            "--host", "127.0.0.1",
            "--port", str(port),
            "--jinja",
            "--no-webui",
            "--ctx-size", str(LOCAL_CONTEXT_WINDOW),
            "--reasoning-budget", "16384",
            "--alias", DEFAULT_MODEL_NAME,
        ],
        stdout=log, stderr=log,
        # Detach from our process group so we survive the parent exiting.
        start_new_session=True,
    )
    pid_path.write_text(str(proc.pid))
    for _ in range(120):
        time.sleep(1)
        if health_check(port):
            click.echo("[server]   ready")
            return
    raise CommandError(
        f"llama-server didn't become ready in 120s",
        f"check {log_path}",
    )


def start() -> None:
    """Start whichever backend is configured. Hosted is config-only."""
    config = read_config()
    if not config:
        raise CommandError(
            "no backend configured",
            "run 'sift init' or 'sift backend local|hosted'",
        )
    kind = config["kind"]
    if kind == "local":
        start_local()
    elif kind == "hosted":
        return
    else:
        raise CommandError(f"unknown backend kind: {kind}")


# ---------------------------------------------------------------------------
# Setup — interactive prompts and one-time installs
# ---------------------------------------------------------------------------

def _ensure_llamacpp() -> None:
    if shutil.which("llama-server"):
        return
    if not shutil.which("brew"):
        raise CommandError(
            "llama-server not installed and Homebrew not found",
            "install Homebrew, or install llama.cpp manually",
        )
    click.echo("[init]     installing llama.cpp via Homebrew (one-time)")
    subprocess.run(["brew", "install", "llama.cpp"], check=True)


def _download_model() -> None:
    models_dir = SIFT_HOME / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    model_path = models_dir / DEFAULT_MODEL_FILE
    if model_path.exists():
        click.echo("[init]     model already downloaded")
        return
    click.echo("[init]     downloading model (~12GB) — go get a coffee")
    # Resolve HF redirect first so curl's progress bar tracks the real
    # download, not the redirect document.
    resolve_url = (
        f"https://huggingface.co/{DEFAULT_MODEL_REPO}"
        f"/resolve/main/{DEFAULT_MODEL_FILE}"
    )
    resp = requests.head(resolve_url, allow_redirects=True, timeout=30)
    resp.raise_for_status()
    resolved = resp.url
    partial = model_path.with_suffix(model_path.suffix + ".partial")
    subprocess.run(
        ["curl", "--fail", "--progress-bar", "--retry", "5",
         "--retry-all-errors", "-o", str(partial), resolved],
        check=True,
    )
    partial.rename(model_path)


def setup_local_interactive() -> None:
    _ensure_llamacpp()
    _download_model()
    write_local()


def setup_hosted_interactive() -> None:
    base_url = click.prompt(
        "OpenAI-compatible base URL (e.g. https://api.openai.com/v1)",
        type=str,
    ).strip()
    if not base_url:
        raise CommandError("base URL required")
    api_key = click.prompt(
        "API key (leave blank for none)",
        hide_input=True, default="", show_default=False,
    )
    model_name = click.prompt(
        "Model name (e.g. gpt-4o, llama-3.3-70b)",
        type=str,
    ).strip()
    if not model_name:
        raise CommandError("model name required")

    click.echo("[init]     checking endpoint...")
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    try:
        resp = requests.get(f"{base_url.rstrip('/')}/models",
                            headers=headers, timeout=10)
        resp.raise_for_status()
    except requests.RequestException as e:
        raise CommandError(
            f"couldn't reach {base_url}/models",
            "check the URL and key",
        ) from e

    write_hosted(base_url, api_key, model_name)


def choose_interactive() -> None:
    click.echo("\nLLM backend:")
    click.echo("  [1] local llama.cpp + Qwen3.6 35B (recommended; ~12 GB download)")
    click.echo("  [2] hosted OpenAI-compatible endpoint (LM Studio, Ollama, OpenAI, …)")
    choice = click.prompt("Choose", default="1", show_default=True)
    if choice == "1":
        setup_local_interactive()
    elif choice == "2":
        setup_hosted_interactive()
    else:
        raise CommandError(f"invalid choice: {choice}")
