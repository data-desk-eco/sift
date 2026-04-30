"""Click entry point. Dispatches:
  sift init                  one-time setup (vault, creds, backend, project)
  sift auto [PROMPT]         agent (REPL if no prompt, headless one-shot otherwise)
  sift backend …             show/switch backend
  sift project …             show/edit project context
  sift vault …               vault management
  sift {search,read,…}       Aleph research tools (pass-through to data plane)

The research tools accept the existing `key=value` style for backwards
compat with SKILL.md and the agent's call sites. Everything else uses
proper Click options."""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
from importlib.resources import files
from pathlib import Path
from typing import Any

import click

from . import backend as _backend
from .client import AlephClient
from .commands import (
    cmd_browse, cmd_cache_clear, cmd_cache_stats, cmd_expand, cmd_hubs,
    cmd_neighbors, cmd_read, cmd_recall, cmd_search, cmd_similar,
    cmd_sources, cmd_sql, cmd_tree,
)
from .errors import CommandError
from .log_filter import stream as log_stream
from .report import export_report
from .store import Store
from .vault import Vault

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

SIFT_HOME = Path.home() / ".sift"
DATA_DIR = files("sift") / "data"

BOOL_KEYS = {"full", "raw", "no_cache"}


def make_vault() -> Vault:
    project_dir = Path(
        os.environ.get("ALEPH_PROJECT_DIR")
        or os.environ.get("SIFT_HOME", str(SIFT_HOME))
    ).expanduser()
    return Vault(project_dir=project_dir)


def make_client() -> AlephClient:
    base = os.environ.get("ALEPH_URL")
    key = os.environ.get("ALEPH_API_KEY")
    if not (base and key):
        vault = make_vault()
        mp = vault.find_mount()
        secrets = vault.read_secrets(mp) if mp else {}
        base = base or secrets.get("ALEPH_URL")
        key = key or secrets.get("ALEPH_API_KEY")
    if not base:
        raise CommandError(
            "ALEPH_URL is not set",
            "set it in the vault: 'sift vault set ALEPH_URL https://aleph.occrp.org'",
        )
    if not key:
        raise CommandError(
            "ALEPH_API_KEY is not set",
            "set it in the vault: 'sift vault set ALEPH_API_KEY <key>'",
        )
    return AlephClient(base_url=base, api_key=key)


def session_db_path() -> Path:
    if override := os.environ.get("ALEPH_DB_PATH"):
        return Path(override).expanduser()
    base = os.environ.get("ALEPH_SESSION_DIR")
    if not base:
        vault = make_vault()
        mp = vault.find_mount()
        base = str(mp / "research") if mp else str(SIFT_HOME)
    return Path(base).expanduser() / "aleph.sqlite"


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
            out.setdefault("_positional", []).append(token)
        i += 1
    for k in list(out.keys()):
        if k in BOOL_KEYS:
            out[k] = str(out[k]).lower() in ("1", "true", "yes", "y")
    return out


def ensure_initialized() -> None:
    if not (SIFT_HOME / ".initialized").exists():
        raise CommandError(
            "sift isn't set up yet",
            "run 'sift init' first",
        )


# ---------------------------------------------------------------------------
# Click root
# ---------------------------------------------------------------------------

class CommandErrorAwareGroup(click.Group):
    """A Click group that surfaces our CommandError with a → suggestion line."""

    def invoke(self, ctx: click.Context) -> Any:
        try:
            return super().invoke(ctx)
        except CommandError as e:
            click.echo(f"[ERROR] {e.message}", err=True)
            if e.suggestion:
                click.echo(f"  → {e.suggestion}", err=True)
            sys.exit(1)


@click.group(cls=CommandErrorAwareGroup,
             context_settings={"help_option_names": ["-h", "--help"]})
def cli() -> None:
    """sift — investigate subjects in Aleph or OpenAleph from your Mac.

    All state lives under ~/.sift (vault, model, backend.json, pi config).
    """


# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

@cli.command()
def init() -> None:
    """One-time setup: vault, Aleph credentials, LLM backend, project context."""
    _require_dep("uv", "brew install uv")
    _require_dep("pi", "npm install -g @mariozechner/pi")
    _require_dep("swiftc", "xcode-select --install")

    SIFT_HOME.mkdir(parents=True, exist_ok=True)
    vault = make_vault()

    if not vault.sparseimage.exists():
        click.echo(f"[init]     creating encrypted vault at {vault.sparseimage}")
        vault.init()
    else:
        click.echo("[init]     vault already exists")
    vault.unlock()

    click.echo("[init]     configuring Aleph credentials")
    aleph_url = click.prompt("Aleph URL",
                             default="https://aleph.occrp.org",
                             show_default=True).strip()
    aleph_key = click.prompt("Aleph API key", hide_input=True).strip()
    if not aleph_key:
        raise CommandError("Aleph API key required")
    mp = vault.find_mount() or vault.unlock()
    vault.write_secret(mp, "ALEPH_URL", aleph_url)
    vault.write_secret(mp, "ALEPH_API_KEY", aleph_key)

    if _backend.read_config() is not None:
        click.echo("[init]     backend already configured (use 'sift backend' to change)")
    else:
        _backend.choose_interactive()

    project_path = SIFT_HOME / "project.md"
    if not project_path.exists():
        click.echo("")
        desc = click.prompt(
            "Briefly describe the project you're working on, as context "
            "for the agent - where do the files come from?",
            default="", show_default=False,
        ).strip()
        if desc:
            project_path.write_text(desc + "\n")
        else:
            click.echo("[init]     skipped — set later with 'sift project set'")
    else:
        click.echo("[init]     project context already set (use 'sift project' to view/edit)")

    (SIFT_HOME / ".initialized").touch()
    click.echo('[init]     done — try: sift auto "investigate <subject>"')


def _require_dep(name: str, hint: str) -> None:
    if not shutil.which(name):
        raise CommandError(
            f"missing dependency: {name}",
            f"install: {hint}",
        )


# ---------------------------------------------------------------------------
# auto
# ---------------------------------------------------------------------------

@cli.command(context_settings={"ignore_unknown_options": True,
                                "allow_extra_args": True})
@click.argument("prompt", required=False)
@click.option("--debug", is_flag=True, help="dump pi's raw JSON event stream")
@click.pass_context
def auto(ctx: click.Context, prompt: str | None, debug: bool) -> None:
    """Run the agent. With PROMPT, headless one-shot; without, interactive REPL."""
    ensure_initialized()
    _backend.start()
    _backend.configure_pi()

    pi_extra = list(ctx.args)
    sysprompt_path = _build_system_prompt()
    skill_path = _skill_dir()

    env = os.environ.copy()
    env["PI_CODING_AGENT_DIR"] = str(SIFT_HOME / "pi")

    # vault exec: mount, populate ALEPH_* env, chdir into the per-session
    # research dir inside the vault so the agent's relative writes (e.g.
    # report.md) land in the encrypted volume.
    vault = make_vault()
    mp = vault.find_mount() or vault.unlock()
    env.update(vault.env_dict(mp))
    if not prompt:
        env.setdefault("ALEPH_SESSION", "default")
        session_dir = mp / "research" / env["ALEPH_SESSION"]
        session_dir.mkdir(parents=True, exist_ok=True)
        os.chdir(session_dir)
        # Interactive REPL — replace this process with pi.
        os.execvpe("pi", [
            "pi",
            "--system-prompt", str(sysprompt_path),
            "--skill", str(skill_path),
        ], env)
        return  # not reached

    env["ALEPH_SESSION"] = _session_name(prompt)
    session_dir = mp / "research" / env["ALEPH_SESSION"]
    session_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(session_dir)

    proc = subprocess.Popen(
        ["pi",
         "--system-prompt", str(sysprompt_path),
         "--skill", str(skill_path),
         "-p", "--mode", "json", prompt, *pi_extra],
        stdout=subprocess.PIPE, stderr=sys.stderr,
        env=env, text=True,
    )
    assert proc.stdout is not None
    for line in log_stream(proc.stdout, debug=debug):
        click.echo(line)
    sys.exit(proc.wait())


def _session_name(prompt: str) -> str:
    import datetime
    import re
    slug = re.sub(r"-+", "-",
                  re.sub(r"[^a-z0-9]", "-", prompt.lower())).strip("-")[:40]
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"{ts}-{slug}" if slug else ts


def _skill_dir() -> Path:
    """The directory pi's --skill points at. pi requires the directory
    name to match the skill name (i.e. `sift`), and to contain only
    SKILL.md — siblings like AGENTS.md or touchid.swift trip pi's
    skill-conflict check."""
    return Path(str(DATA_DIR / "sift"))


def _build_system_prompt() -> Path:
    """Combine AGENTS.md + any project.md into a single sysprompt file."""
    agents_md = (DATA_DIR / "AGENTS.md").read_text()
    project_path = SIFT_HOME / "project.md"
    parts = [agents_md]
    if project_path.exists():
        parts.append("\n\n## Project context\n\n" + project_path.read_text())
    out = SIFT_HOME / "system-prompt.md"
    out.write_text("".join(parts))
    return out


# ---------------------------------------------------------------------------
# backend
# ---------------------------------------------------------------------------

def _show_backend() -> None:
    config = _backend.read_config()
    if not config:
        raise CommandError(
            "no backend configured",
            "run 'sift init' or 'sift backend local|hosted'",
        )
    click.echo(_backend.backend_path().read_text(), nl=False)


@cli.group("backend", invoke_without_command=True)
@click.pass_context
def backend(ctx: click.Context) -> None:
    """Show or switch the LLM backend."""
    if ctx.invoked_subcommand is None:
        _show_backend()


@backend.command("show")
def backend_show() -> None:
    """Show the current backend config."""
    _show_backend()


@backend.command("local")
def backend_local() -> None:
    """Switch to local llama.cpp + Qwen3.6 35B."""
    _backend.setup_local_interactive()


@backend.command("hosted")
def backend_hosted() -> None:
    """Switch to a hosted OpenAI-compatible endpoint."""
    _backend.setup_hosted_interactive()


# ---------------------------------------------------------------------------
# project
# ---------------------------------------------------------------------------

PROJECT_PROMPT = (
    "Briefly describe the project you're working on, as context "
    "for the agent - where do the files come from?"
)


@cli.group(invoke_without_command=True)
@click.pass_context
def project(ctx: click.Context) -> None:
    """Show or edit the project description prepended to the agent's system prompt."""
    if ctx.invoked_subcommand is None:
        _project_show()


@project.command("show")
def project_show_cmd() -> None:
    """Show the current project description."""
    _project_show()


def _project_show() -> None:
    path = SIFT_HOME / "project.md"
    if not path.exists():
        raise CommandError(
            "no project context set",
            "run 'sift init' or 'sift project set'",
        )
    click.echo(path.read_text(), nl=False)


@project.command("set")
@click.argument("description", required=False)
def project_set(description: str | None) -> None:
    """Set the project description (interactively if no DESCRIPTION arg)."""
    if not description:
        description = click.prompt(PROJECT_PROMPT, type=str).strip()
    if not description:
        raise CommandError("description required")
    path = SIFT_HOME / "project.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(description + "\n")
    click.echo(f"[project]  saved to {path}")


@project.command("edit")
def project_edit() -> None:
    """Open the project description in $EDITOR."""
    path = SIFT_HOME / "project.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    editor = os.environ.get("EDITOR", "vi")
    subprocess.run([editor, str(path)], check=False)


@project.command("clear")
def project_clear() -> None:
    """Remove the project description."""
    path = SIFT_HOME / "project.md"
    if path.exists():
        path.unlink()
    click.echo("[project]  cleared")


# ---------------------------------------------------------------------------
# vault
# ---------------------------------------------------------------------------

@cli.group()
def vault() -> None:
    """Vault management."""


@vault.command("init")
@click.option("--size", default=Vault.DEFAULT_SIZE, show_default=True,
              help="sparseimage max size (e.g. 20g, 100g)")
def vault_init_cmd(size: str) -> None:
    """Create the encrypted sparseimage."""
    v = make_vault()
    mp = v.init(size=size)
    click.echo(f"✔ vault initialised\n"
               f"  sparseimage : {v.sparseimage}\n"
               f"  mounted at  : {mp}\n"
               f"  passphrase  : {v.passphrase_file} (mode 0600)\n\n"
               f"Add your Aleph credentials:\n"
               f"  sift vault set ALEPH_URL https://aleph.occrp.org\n"
               f"  sift vault set ALEPH_API_KEY <your-key>")


@vault.command("unlock")
def vault_unlock_cmd() -> None:
    """Mount the vault (Touch ID gated)."""
    click.echo(str(make_vault().unlock()))


@vault.command("lock")
def vault_lock_cmd() -> None:
    """Unmount the vault."""
    click.echo("locked." if make_vault().lock() else "not mounted.")


@vault.command("status")
def vault_status_cmd() -> None:
    """Show whether the vault is mounted."""
    v = make_vault()
    if not v.sparseimage.exists():
        raise CommandError("uninitialised",
                           f"run 'sift vault init' to create {v.sparseimage}")
    mp = v.find_mount()
    click.echo(f"mounted at {mp}" if mp else "locked")


@vault.command("set")
@click.argument("key")
@click.argument("value")
def vault_set_cmd(key: str, value: str) -> None:
    """Store a secret in the vault."""
    v = make_vault()
    mp = v.find_mount()
    if not mp:
        raise CommandError("vault is not mounted", "run 'sift vault unlock'")
    v.write_secret(mp, key, value)
    click.echo(f"set {key}")


@vault.command("get")
@click.argument("key")
def vault_get_cmd(key: str) -> None:
    """Read a secret from the vault."""
    v = make_vault()
    mp = v.find_mount()
    if not mp:
        raise CommandError("vault is not mounted", "run 'sift vault unlock'")
    secrets = v.read_secrets(mp)
    if key not in secrets:
        raise CommandError(f"no secret named '{key}'")
    click.echo(secrets[key])


@vault.command("list")
def vault_list_cmd() -> None:
    """List secret keys (values not shown)."""
    v = make_vault()
    mp = v.find_mount()
    if not mp:
        raise CommandError("vault is not mounted", "run 'sift vault unlock'")
    keys = v.list_secrets(mp)
    click.echo("\n".join(keys) if keys else "(empty)")


@vault.command("env")
def vault_env_cmd() -> None:
    """Print export statements for the vault's env (eval-friendly)."""
    v = make_vault()
    mp = v.find_mount()
    if not mp:
        raise CommandError("vault is not mounted", "run 'sift vault unlock'")
    env = v.env_dict(mp)
    env.setdefault("ALEPH_SESSION", os.environ.get("ALEPH_SESSION", "default"))
    for k, val in env.items():
        click.echo(f"export {k}={shlex.quote(val)}")


# ---------------------------------------------------------------------------
# Research tools — pass-through key=value parsing, kept for SKILL.md compat
# ---------------------------------------------------------------------------

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

# Local-only commands operate purely against the cache DB — no Aleph
# round-trip, no client construction, no vault unlock required.
LOCAL_TOOLS = {
    "neighbors": cmd_neighbors,
    "recall": cmd_recall,
    "sql": cmd_sql,
}


def _make_research_command(name: str):
    @click.pass_context
    def _cmd(ctx: click.Context) -> None:
        args = parse_kv_args(ctx.args)
        pos = args.pop("_positional", None)
        if pos and "query" not in args and name in ("search", "hubs"):
            args["query"] = " ".join(pos)
        elif pos and "alias" not in args and name in (
            "read", "browse", "expand", "similar", "tree",
        ):
            args["alias"] = pos[0]
        elif pos and "grep" not in args and name == "sources":
            args["grep"] = " ".join(pos)

        store = Store(session_db_path())
        client = make_client()
        out = TOOLS[name](client, store, args)
        click.echo(out)

    _cmd.__name__ = name
    return _cmd


def _make_local_command(name: str):
    @click.pass_context
    def _cmd(ctx: click.Context) -> None:
        args = parse_kv_args(ctx.args)
        pos = args.pop("_positional", None)
        if pos and "alias" not in args and name == "neighbors":
            args["alias"] = pos[0]
        elif pos and "query" not in args and name == "sql":
            args["query"] = " ".join(pos)

        store = Store(session_db_path())
        out = LOCAL_TOOLS[name](store, args)
        click.echo(out)

    _cmd.__name__ = name
    return _cmd


for _name in TOOLS:
    cli.command(
        _name,
        context_settings={"ignore_unknown_options": True,
                          "allow_extra_args": True},
        help=f"Aleph: {_name} (key=value args; see SKILL.md)",
    )(_make_research_command(_name))


for _name in LOCAL_TOOLS:
    cli.command(
        _name,
        context_settings={"ignore_unknown_options": True,
                          "allow_extra_args": True},
        help=f"Cache: {_name} (key=value args; see SKILL.md)",
    )(_make_local_command(_name))


# ---------------------------------------------------------------------------
# cache subgroup — stats and clear
# ---------------------------------------------------------------------------

@cli.group("cache", invoke_without_command=True)
@click.pass_context
def cache_group(ctx: click.Context) -> None:
    """Inspect or prune the local response cache."""
    if ctx.invoked_subcommand is None:
        store = Store(session_db_path())
        click.echo(cmd_cache_stats(store, {}))


@cache_group.command("stats")
def cache_stats_cmd() -> None:
    """Show cache size, counts, and age."""
    store = Store(session_db_path())
    click.echo(cmd_cache_stats(store, {}))


@cache_group.command("clear", context_settings={"ignore_unknown_options": True,
                                                 "allow_extra_args": True})
@click.pass_context
def cache_clear_cmd(ctx: click.Context) -> None:
    """Truncate the response cache (entities/aliases/edges preserved)."""
    args = parse_kv_args(ctx.args)
    store = Store(session_db_path())
    click.echo(cmd_cache_clear(store, args))


# ---------------------------------------------------------------------------
# export — markdown report → HTML, alias refs → Aleph entity links
# ---------------------------------------------------------------------------

@cli.command("export")
@click.argument("src", type=click.Path(exists=True, dir_okay=False, path_type=Path),
                default=Path("report.md"), required=False)
@click.option("--out", "-o", "dst", type=click.Path(dir_okay=False, path_type=Path),
              default=None, help="output file (default: SRC with .html extension)")
@click.option("--server", default=None,
              help="Aleph base URL for entity links (default: ALEPH_URL from vault)")
def export_cmd(src: Path, dst: Path | None, server: str | None) -> None:
    """Render report.md → report.html, turning every r-alias into a proper
    link to the entity on its Aleph server."""
    if dst is None:
        dst = src.with_suffix(".html")

    if not server:
        server = os.environ.get("ALEPH_URL")
        if not server:
            vault = make_vault()
            mp = vault.find_mount()
            if mp:
                server = (vault.read_secrets(mp) or {}).get("ALEPH_URL")
    if not server:
        raise CommandError(
            "no Aleph server URL — can't build entity links",
            "pass --server https://aleph.example.org or set ALEPH_URL in the vault",
        )

    store = Store(session_db_path())
    counts = export_report(src, dst, store, default_server=server)
    msg = f"[export]   {src} → {dst}  ({counts.linked} aliases linked"
    if counts.unresolved:
        msg += f", {counts.unresolved} unresolved"
    msg += ")"
    click.echo(msg)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    try:
        cli.main(standalone_mode=False)
    except click.exceptions.Abort:
        click.echo("Aborted.", err=True)
        return 1
    except click.exceptions.UsageError as e:
        e.show()
        return e.exit_code or 2
    except click.exceptions.ClickException as e:
        e.show()
        return e.exit_code
    except CommandError as e:
        click.echo(f"[ERROR] {e.message}", err=True)
        if e.suggestion:
            click.echo(f"  → {e.suggestion}", err=True)
        return 1
    except SystemExit as e:
        return int(e.code) if isinstance(e.code, int) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
