"""Backend config — $SIFT_HOME/backend.json plus the pi provider files
under $SIFT_HOME/pi/. Lives on the Python side so the bash front-end
doesn't have to assemble JSON by string concatenation."""

from __future__ import annotations

import json
import os
from pathlib import Path

from .errors import CommandError

DEFAULT_LOCAL_PORT = 1234


def _project_dir() -> Path:
    # SIFT_HOME is exported as ALEPH_PROJECT_DIR by bin/sift.
    base = os.environ.get("ALEPH_PROJECT_DIR") or os.environ.get("SIFT_HOME")
    if not base:
        raise CommandError("SIFT_HOME / ALEPH_PROJECT_DIR not set")
    return Path(base).expanduser()


def _backend_path() -> Path:
    return _project_dir() / "backend.json"


def _write_json(path: Path, data: dict, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")
    path.chmod(mode)


def get_field(key: str) -> str:
    """Read a string field from backend.json. Empty if file or key missing."""
    try:
        data = json.loads(_backend_path().read_text())
    except FileNotFoundError:
        return ""
    return str(data.get(key, ""))


def write_local(model_file: str, model_name: str,
                port: int = DEFAULT_LOCAL_PORT) -> None:
    _write_json(_backend_path(), {
        "kind": "local",
        "model_file": model_file,
        "model_name": model_name,
        "port": port,
    })


def write_hosted(base_url: str, api_key: str, model_name: str) -> None:
    _write_json(_backend_path(), {
        "kind": "hosted",
        "base_url": base_url,
        "api_key": api_key,
        "model_name": model_name,
    })


def configure_pi() -> None:
    """Write pi/models.json and pi/settings.json so pi talks to our backend."""
    home = _project_dir()
    backend = json.loads(_backend_path().read_text())
    if backend["kind"] == "local":
        port = backend.get("port", DEFAULT_LOCAL_PORT)
        base_url = f"http://127.0.0.1:{port}/v1"
        api_key = "sift-local"
        display = "Qwen3.6 35B A3B (local)"
    else:
        base_url = backend["base_url"]
        api_key = backend.get("api_key", "")
        display = backend["model_name"]
    model = backend["model_name"]
    pi_dir = home / "pi"
    pi_dir.mkdir(parents=True, exist_ok=True)
    (pi_dir / "models.json").write_text(json.dumps({
        "providers": {"sift": {
            "baseUrl": base_url,
            "api": "openai-completions",
            "apiKey": api_key,
            "compat": {"supportsDeveloperRole": False, "supportsReasoningEffort": False},
            "models": [{"id": model, "name": display}],
        }},
    }, indent=2) + "\n")
    (pi_dir / "settings.json").write_text(json.dumps({
        "defaultProvider": "sift",
        "defaultModel": model,
    }, indent=2) + "\n")
