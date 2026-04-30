"""CLI entry point. Dispatches `sift <tool>` to a research command and
`sift vault <subcmd>` to vault management. Wires up the Store, the
AlephClient (with vault-secrets fallback), and the Vault. Errors are
caught and rendered with a `→ suggestion` line where one was attached."""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

from . import backend
from .client import AlephClient
from .commands import (
    cmd_browse, cmd_expand, cmd_hubs, cmd_read, cmd_search,
    cmd_similar, cmd_sources, cmd_tree,
)
from .errors import CommandError
from .store import Store
from .vault import Vault

# Package's share/ — where touchid.swift lives. Layout: <pkg>/lib/tool/cli.py,
# <pkg>/share/. Three parents up gets us to <pkg>.
SHARE_DIR = Path(__file__).resolve().parent.parent.parent / "share"


TOOLS = {
    "search": cmd_search,
    "read": cmd_read,
    "sources": cmd_sources,
    "hubs": cmd_hubs,
    "similar": cmd_similar,
    "expand": cmd_expand,
    "browse": cmd_browse,
    "tree": cmd_tree,
}

BOOL_KEYS = {"full", "raw", "no_cache"}


def parse_kv_args(raw: list[str]) -> dict:
    """Accept both `key=value` and `--key value` / `--key=value`."""
    out: dict[str, Any] = {}
    i = 0
    while i < len(raw):
        token = raw[i]
        if token.startswith("--"):
            body = token[2:]
            if "=" in body:
                k, v = body.split("=", 1)
            else:
                k = body
                if i + 1 < len(raw) and not raw[i + 1].startswith("--"):
                    v = raw[i + 1]
                    i += 1
                else:
                    v = "true"
            out[k] = v
        elif "=" in token:
            k, v = token.split("=", 1)
            out[k] = v
        else:
            # Bare positional — first one becomes `query` for search-like tools.
            out.setdefault("_positional", []).append(token)
        i += 1

    # Normalise booleans.
    for k in list(out.keys()):
        if k in BOOL_KEYS:
            v = str(out[k]).lower()
            out[k] = v in ("1", "true", "yes", "y")
    return out


def find_project_dir() -> Path:
    """Locate the project that owns the vault.

    Resolution order:
      1. $ALEPH_PROJECT_DIR (explicit override)
      2. Walk up from cwd looking for an existing .vault.sparseimage
      3. Fall back to cwd (used by `sift vault init` to create a new vault)
    """
    override = os.environ.get("ALEPH_PROJECT_DIR")
    if override:
        return Path(override).expanduser().resolve()
    cwd = Path.cwd().resolve()
    for d in (cwd, *cwd.parents):
        if (d / Vault.SPARSEIMAGE_NAME).exists():
            return d
    return cwd


def make_vault() -> Vault:
    return Vault(project_dir=find_project_dir(), share_dir=SHARE_DIR)


def _vault_secrets_if_mounted() -> dict:
    """If a vault is mounted for the current project, read its secrets.json.
    Used so the agent doesn't need explicit env juggling when invoked from
    a project directory with a mounted vault."""
    vault = make_vault()
    mp = vault.find_mount()
    return vault.read_secrets(mp) if mp else {}


def session_db_path() -> Path:
    override = os.environ.get("ALEPH_DB_PATH")
    if override:
        return Path(override).expanduser()
    base = os.environ.get("ALEPH_SESSION_DIR")
    if not base:
        vault = make_vault()
        mp = vault.find_mount()
        base = str(mp / "research") if mp else "~/.sift"
    return Path(base).expanduser() / "aleph.sqlite"


def make_client() -> AlephClient:
    base = os.environ.get("ALEPH_URL")
    key = os.environ.get("ALEPH_API_KEY")
    if not (base and key):
        secrets = _vault_secrets_if_mounted()
        base = base or secrets.get("ALEPH_URL")
        key = key or secrets.get("ALEPH_API_KEY")
    if not base:
        raise CommandError(
            "ALEPH_URL is not set",
            "set it in the vault: 'sift vault set ALEPH_URL https://aleph.occrp.org', "
            "or export it",
        )
    if not key:
        raise CommandError(
            "ALEPH_API_KEY is not set",
            "set it in the vault: 'sift vault set ALEPH_API_KEY <key>', or export it",
        )
    return AlephClient(base_url=base, api_key=key)


# ---------------------------------------------------------------------------
# Vault subcommands
# ---------------------------------------------------------------------------


def vault_init(vault: Vault, args: list[str]) -> str:
    size = Vault.DEFAULT_SIZE
    a = parse_kv_args(args)
    if a.get("size"):
        size = a["size"]
    mp = vault.init(size=size)
    return (
        f"✔ vault initialised\n"
        f"  sparseimage : {vault.sparseimage}\n"
        f"  mounted at  : {mp}\n"
        f"  passphrase  : {vault.passphrase_file} (mode 0600)\n\n"
        f"Add your Aleph credentials:\n"
        f"  sift vault set ALEPH_URL https://aleph.occrp.org\n"
        f"  sift vault set ALEPH_API_KEY <your-key>"
    )


def vault_unlock(vault: Vault, args: list[str]) -> str:
    return str(vault.unlock())


def vault_lock(vault: Vault, args: list[str]) -> str:
    return "locked." if vault.lock() else "not mounted."


def _require_mount(vault: Vault) -> Path:
    mp = vault.find_mount()
    if not mp:
        raise CommandError("vault is not mounted", "run 'sift vault unlock'")
    return mp


def vault_status(vault: Vault, args: list[str]) -> str:
    if not vault.sparseimage.exists():
        raise CommandError("uninitialised", f"run 'sift vault init' to create {vault.sparseimage}")
    mp = vault.find_mount()
    return f"mounted at {mp}" if mp else "locked"


def vault_mountpoint(vault: Vault, args: list[str]) -> str:
    return str(_require_mount(vault))


def vault_env(vault: Vault, args: list[str]) -> str:
    env = vault.env_dict(_require_mount(vault))
    if "ALEPH_SESSION" not in os.environ:
        env["ALEPH_SESSION"] = "default"
    return "\n".join(f"export {k}={shlex.quote(v)}" for k, v in env.items())


def vault_exec(vault: Vault, args: list[str]) -> str:
    if not args:
        raise CommandError("vault exec: requires a command")
    mp = vault.find_mount() or vault.unlock()
    new_env = os.environ.copy()
    new_env.update(vault.env_dict(mp))
    new_env.setdefault("ALEPH_SESSION", "default")
    # Chdir into the session dir so the child's cwd is inside the vault.
    # Without this, an agent that resolves a relative path (e.g.
    # `research/<session>/report.md`) ends up writing into the caller's
    # project directory rather than the encrypted vault.
    session_dir = mp / "research" / new_env["ALEPH_SESSION"]
    session_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(session_dir)
    os.execvpe(args[0], args, new_env)


def vault_set(vault: Vault, args: list[str]) -> str:
    if len(args) != 2:
        raise CommandError("vault set: usage 'sift vault set <KEY> <VALUE>'")
    vault.write_secret(_require_mount(vault), args[0], args[1])
    return f"set {args[0]}"


def vault_get(vault: Vault, args: list[str]) -> str:
    if len(args) != 1:
        raise CommandError("vault get: usage 'sift vault get <KEY>'")
    secrets = vault.read_secrets(_require_mount(vault))
    if args[0] not in secrets:
        raise CommandError(f"no secret named '{args[0]}'")
    return secrets[args[0]]


def vault_list(vault: Vault, args: list[str]) -> str:
    keys = vault.list_secrets(_require_mount(vault))
    return "\n".join(keys) if keys else "(empty)"


# ---------------------------------------------------------------------------
# Backend subcommands (called from bin/sift; not user-facing)
# ---------------------------------------------------------------------------


def backend_get(args: list[str]) -> str:
    if len(args) != 1:
        raise CommandError("backend get: usage 'backend get <KEY>'")
    return backend.get_field(args[0])


def backend_write_local(args: list[str]) -> str:
    if len(args) != 2:
        raise CommandError("backend write-local: usage '<model_file> <model_name>'")
    backend.write_local(args[0], args[1])
    return ""


def backend_write_hosted(args: list[str]) -> str:
    """Reads the api key from stdin so it never appears in argv."""
    if len(args) != 2:
        raise CommandError(
            "backend write-hosted: usage '<base_url> <model_name>'  (api_key on stdin)"
        )
    api_key = sys.stdin.read().rstrip("\n")
    backend.write_hosted(args[0], api_key, args[1])
    return ""


def backend_configure_pi(args: list[str]) -> str:
    if args:
        raise CommandError("backend configure-pi: takes no args (port comes from backend.json)")
    backend.configure_pi()
    return ""


BACKEND_SUBCMDS = {
    "get": backend_get,
    "write-local": backend_write_local,
    "write-hosted": backend_write_hosted,
    "configure-pi": backend_configure_pi,
}


VAULT_SUBCMDS = {
    "init": vault_init,
    "unlock": vault_unlock,
    "open": vault_unlock,
    "lock": vault_lock,
    "close": vault_lock,
    "status": vault_status,
    "mountpoint": vault_mountpoint,
    "env": vault_env,
    "exec": vault_exec,
    "set": vault_set,
    "get": vault_get,
    "list": vault_list,
}


def usage() -> str:
    return (
        "sift-tool — internal helper. The user-facing CLI is `sift`.\n\n"
        "usage: sift <tool> [key=value ...]\n"
        "       sift vault <subcmd> [args ...]\n\n"
        f"tools: {', '.join(TOOLS.keys())}\n"
        f"vault: {', '.join(sorted(set(VAULT_SUBCMDS.keys())))}\n\n"
        "config (env, with vault auto-discovery):\n"
        "  ALEPH_URL, ALEPH_API_KEY              # falls back to vault secrets.json\n"
        "  ALEPH_SESSION, ALEPH_SESSION_DIR      # falls back to <vault>/research\n"
        "  ALEPH_DB_PATH                         # default: $ALEPH_SESSION_DIR/aleph.sqlite\n\n"
        "see share/SKILL.md for tool reference."
    )


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(usage())
        return 0

    tool = sys.argv[1]

    # Backend subcommands (called from bin/sift).
    if tool == "backend":
        if len(sys.argv) < 3 or sys.argv[2] not in BACKEND_SUBCMDS:
            print(f"[ERROR] usage: sift-tool backend <{'|'.join(BACKEND_SUBCMDS)}>",
                  file=sys.stderr)
            return 2
        try:
            out = BACKEND_SUBCMDS[sys.argv[2]](sys.argv[3:])
        except CommandError as e:
            msg = f"[ERROR] {e.message}"
            if e.suggestion:
                msg += f"\n  → {e.suggestion}"
            print(msg, file=sys.stderr)
            return 1
        if out:
            print(out)
        return 0

    # Vault subcommands.
    if tool == "vault":
        if len(sys.argv) < 3:
            print(usage(), file=sys.stderr)
            return 2
        sub = sys.argv[2]
        if sub not in VAULT_SUBCMDS:
            print(f"[ERROR] unknown vault subcommand '{sub}'\n{usage()}",
                  file=sys.stderr)
            return 2
        try:
            out = VAULT_SUBCMDS[sub](make_vault(), sys.argv[3:])
        except CommandError as e:
            msg = f"[ERROR] {e.message}"
            if e.suggestion:
                msg += f"\n  → {e.suggestion}"
            print(msg, file=sys.stderr)
            return 1
        except subprocess.CalledProcessError as e:
            tail = (e.stderr or b"").decode("utf-8", "replace").strip()
            print(f"[ERROR] hdiutil failed (rc={e.returncode}): {tail}",
                  file=sys.stderr)
            return 1
        if out:
            print(out)
        return 0

    if tool not in TOOLS:
        print(f"[ERROR] unknown tool '{tool}'\n{usage()}", file=sys.stderr)
        return 2

    args = parse_kv_args(sys.argv[2:])
    # First positional (e.g. `sift search "louis goddard"`) → query.
    pos = args.pop("_positional", None)
    if pos and "query" not in args and tool in ("search", "hubs"):
        args["query"] = " ".join(pos)
    elif pos and "alias" not in args and tool in ("read", "browse", "expand", "similar", "tree"):
        args["alias"] = pos[0]
    elif pos and "grep" not in args and tool == "sources":
        args["grep"] = " ".join(pos)

    try:
        store = Store(session_db_path())
        client = make_client()
        out = TOOLS[tool](client, store, args)
    except CommandError as e:
        msg = f"[ERROR] {e.message}"
        if e.suggestion:
            msg += f"\n  → {e.suggestion}"
        print(msg, file=sys.stderr)
        return 1
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        return 1

    print(out)
    return 0
