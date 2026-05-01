"""Click entry point. Dispatches:
  sift init                  one-time setup (vault, creds, backend, project)
  sift auto [PROMPT]         agent (REPL if no prompt, headless one-shot otherwise)
  sift backend …             show/switch backend
  sift project …             show/edit project context
  sift vault …               vault management
  sift {search,read,…}       Aleph research tools

Research and cache tools use standard POSIX `--flag value` syntax (with
`-l`/`-f`/`-r`/`-o` shorthands) and a single positional for the obvious
argument (query / alias). This lets the agent reach for the same muscle
memory it has for any other UNIX command instead of memorising bespoke
syntax."""

from __future__ import annotations

import datetime
import os
import re
import shlex
import shutil
import subprocess
import sys
import time as _time
from importlib.resources import files
from pathlib import Path
from typing import Any

import click
import requests

from . import backend as _backend
from .client import AlephClient
from .commands import (
    cmd_browse, cmd_cache_clear, cmd_cache_stats, cmd_expand, cmd_hubs,
    cmd_neighbors, cmd_read, cmd_recall, cmd_search, cmd_similar,
    cmd_sources, cmd_sql, cmd_tree,
)
from .errors import CommandError
from .events import stream as log_stream
from .report import export_report
from .store import Store
from .vault import Vault

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

SIFT_HOME = Path.home() / ".sift"
DATA_DIR = files("sift") / "data"


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
@click.option("--time-limit", "-t", "time_limit", default=None,
              help="soft deadline (e.g. 30m, 1h30m, 90s); the agent self-paces against it")
@click.option("--new", "-n", "new", is_flag=True, default=False,
              help="start a fresh session instead of continuing the most "
                   "recent one. Required when switching to a different "
                   "subject of investigation.")
@click.pass_context
def auto(ctx: click.Context, prompt: str | None, debug: bool,
         time_limit: str | None, new: bool) -> None:
    """Run the agent. By default continues the most recent session — pi reloads
    its conversation history and the agent's cwd is the original session dir,
    so findings.db and report.md keep growing in place.

    Pass --new to start fresh (e.g. when changing subject of investigation).
    With PROMPT, runs headless one-shot; without, drops into an interactive
    REPL."""
    # Parse duration first so a bad value fails before we spin up the backend.
    deadline = _set_deadline(time_limit) if time_limit else None

    ensure_initialized()
    _backend.start()
    _backend.configure_pi()

    pi_extra = list(ctx.args)
    sysprompt_path = _build_system_prompt(deadline=deadline)
    skill_path = _skill_dir()

    env = os.environ.copy()
    env["PI_CODING_AGENT_DIR"] = str(SIFT_HOME / "pi")
    if deadline:
        env["SIFT_DEADLINE_TS"] = str(deadline[1])
        env["SIFT_DEADLINE_START_TS"] = str(deadline[0])

    # vault exec: mount, populate ALEPH_* env, chdir into the per-session
    # research dir inside the vault so the agent's relative writes (e.g.
    # report.md) land in the encrypted volume.
    vault = make_vault()
    mp = vault.find_mount() or vault.unlock()
    env.update(vault.env_dict(mp))

    last = None if new else _last_session(mp)
    if last is not None:
        session_dir = last
        age_h = (_time.time() - last.stat().st_mtime) / 3600
        if age_h >= STALE_SESSION_HOURS:
            click.echo(
                f"[auto]     resuming {session_dir.name} "
                f"({_fmt_age(age_h)} since last activity — pass --new if "
                f"this is a different investigation)",
                err=True,
            )
        else:
            click.echo(f"[auto]     resuming {session_dir.name}", err=True)
    elif prompt:
        session_dir = mp / "research" / _new_session_name(prompt)
        click.echo(f"[auto]     session: {session_dir.name}", err=True)
    else:
        name = env.get("ALEPH_SESSION", "default")
        session_dir = mp / "research" / name
        click.echo(f"[auto]     session: {session_dir.name}", err=True)

    session_dir.mkdir(parents=True, exist_ok=True)
    env["ALEPH_SESSION"] = session_dir.name
    env["SIFT_FINDINGS_DB"] = str(session_dir / "findings.db")
    os.chdir(session_dir)

    pi_session_dir = session_dir / ".pi-sessions"
    has_history = pi_session_dir.exists() and any(pi_session_dir.iterdir())
    pi_session_dir.mkdir(parents=True, exist_ok=True)

    pi_args = [
        "pi",
        "--system-prompt", str(sysprompt_path),
        "--skill", str(skill_path),
        "--session-dir", str(pi_session_dir),
    ]
    resuming = last is not None
    if resuming:
        if has_history:
            pi_args.append("--continue")
        else:
            click.echo(
                "[auto]     no prior pi history in this session — starting "
                "cold. report.md and findings.db are still available.",
                err=True,
            )

    if not prompt:
        # Interactive REPL — replace this process with pi.
        os.execvpe("pi", pi_args, env)
        return  # not reached

    proc = subprocess.Popen(
        pi_args + ["-p", "--mode", "json", prompt, *pi_extra],
        stdout=subprocess.PIPE, stderr=sys.stderr,
        env=env, text=True,
    )
    assert proc.stdout is not None
    for line in log_stream(proc.stdout, debug=debug):
        click.echo(line)
    sys.exit(proc.wait())


def _new_session_name(prompt: str) -> str:
    """Build `<timestamp>-<slug>` for a fresh session. Tries the configured
    backend for a clean 2-5 word slug; falls back to a regex slug of the
    prompt if the model call fails."""
    slug = _ai_slug(prompt) or _regex_slug(prompt)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"{ts}-{slug}" if slug else ts


def _regex_slug(prompt: str) -> str:
    return re.sub(r"-+", "-",
                  re.sub(r"[^a-z0-9]", "-", prompt.lower())).strip("-")[:40]


def _sanitize_slug(text: str) -> str:
    """Take whatever the model spat out and beat it into a kebab-case slug."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines:
        return ""
    candidate = lines[-1].strip().strip("`'\"").strip()
    slug = re.sub(r"[^a-z0-9-]+", "-", candidate.lower())
    return re.sub(r"-+", "-", slug).strip("-")[:50]


def _ai_slug(prompt: str, timeout: float = 8.0) -> str | None:
    """Ask the configured backend for a kebab-case session slug. Returns
    None on any error so the caller can fall back to a regex slug."""
    config = _backend.read_config()
    if not config:
        return None
    if config["kind"] == "local":
        port = config.get("port", _backend.DEFAULT_LOCAL_PORT)
        base_url = f"http://127.0.0.1:{port}/v1"
        api_key = "sift-local"
    else:
        base_url = config["base_url"]
        api_key = config.get("api_key", "")
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    body = {
        "model": config["model_name"],
        "messages": [
            {"role": "system",
             "content": ("You name research sessions with a short slug. "
                         "Output only the slug — 2 to 5 lowercase words "
                         "separated by hyphens, no punctuation, no quotes, "
                         "no commentary, no preface. Focus on the subject "
                         "of the investigation, not generic verbs.")},
            {"role": "user", "content": f"Investigation: {prompt}"},
        ],
        "max_tokens": 32,
        "temperature": 0.2,
    }
    try:
        resp = requests.post(f"{base_url.rstrip('/')}/chat/completions",
                             headers=headers, json=body, timeout=timeout)
        resp.raise_for_status()
        text = resp.json()["choices"][0]["message"]["content"] or ""
    except (requests.RequestException, KeyError, ValueError):
        return None
    return _sanitize_slug(text) or None


STALE_SESSION_HOURS = 24


def _last_session(mp: Path) -> Path | None:
    """Most recently modified session dir under `<vault>/research/`, or None
    if none exists. Skips the bare `default` REPL session so it doesn't
    silently absorb a `sift auto "PROMPT"` call from a different subject."""
    research = mp / "research"
    if not research.exists():
        return None
    candidates = sorted(
        (p for p in research.iterdir() if p.is_dir() and p.name != "default"),
        key=lambda p: p.stat().st_mtime, reverse=True,
    )
    return candidates[0] if candidates else None


def _fmt_age(hours: float) -> str:
    if hours < 48:
        return f"{int(hours)}h"
    return f"{int(hours / 24)}d"


def _strip_frontmatter(text: str) -> str:
    if not text.startswith("---"):
        return text
    end = text.find("\n---", 3)
    if end == -1:
        return text
    return text[end + 4:].lstrip("\n")


def _skill_dir() -> Path:
    """The directory pi's --skill points at. pi requires the directory
    name to match the skill name (i.e. `sift`), and to contain only
    SKILL.md — siblings like AGENTS.md or touchid.swift trip pi's
    skill-conflict check."""
    return Path(str(DATA_DIR / "sift"))


def _build_system_prompt(deadline: tuple[int, int] | None = None) -> Path:
    """Combine AGENTS.md + SKILL.md + any project.md into a single sysprompt
    file. SKILL.md is also exposed via pi's `--skill` flag for discoverability,
    but baking it into turn 1 ensures the agent never reaches for argparse-style
    flags the CLI doesn't accept (it used to silently smuggle `-f` into `alias`).

    If `deadline` is set (start_ts, end_ts), append a soft-deadline note so
    the agent knows to call `sift time` and self-pace."""
    agents_md = (DATA_DIR / "AGENTS.md").read_text()
    skill_md = _strip_frontmatter((DATA_DIR / "sift" / "SKILL.md").read_text())
    project_path = SIFT_HOME / "project.md"
    parts = [agents_md, "\n\n", skill_md]
    if project_path.exists():
        parts.append("\n\n## Project context\n\n" + project_path.read_text())
    if deadline:
        start, end = deadline
        total_min = max(1, (end - start) // 60)
        end_local = _time.strftime("%H:%M", _time.localtime(end))
        parts.append(
            f"\n\n## Deadline\n\n"
            f"This session has a soft deadline of {total_min} minute(s), "
            f"ending around {end_local} local time. After every few tool calls, "
            f"run `sift time` to see remaining time and pacing guidance, and "
            f"adjust depth accordingly. The deadline is soft — there's no hard "
            f"kill — but report.md must exist by the time you stop."
        )
    out = SIFT_HOME / "system-prompt.md"
    out.write_text("".join(parts))
    return out


_DURATION_RE = re.compile(r"(\d+)\s*([smh])", re.IGNORECASE)


def _parse_duration(s: str) -> int:
    """Parse "30m", "1h30m", "90s" → seconds. Raises click.BadParameter."""
    cleaned = s.replace(" ", "")
    if not cleaned:
        raise click.BadParameter("empty duration")
    total = 0
    consumed = 0
    for m in _DURATION_RE.finditer(cleaned):
        n, unit = int(m.group(1)), m.group(2).lower()
        total += n * {"s": 1, "m": 60, "h": 3600}[unit]
        consumed += len(m.group(0))
    if total <= 0 or consumed != len(cleaned):
        raise click.BadParameter(
            f"can't parse {s!r} (try 30m, 1h, 90s, 1h30m)"
        )
    return total


def _set_deadline(time_limit: str) -> tuple[int, int]:
    """Parse --time-limit into (start_ts, end_ts). Raises on bad input."""
    seconds = _parse_duration(time_limit)
    start = int(_time.time())
    return start, start + seconds


# ---------------------------------------------------------------------------
# time (agent self-pacing)
# ---------------------------------------------------------------------------

@cli.command("time")
def time_cmd() -> None:
    """Show remaining time and pacing phase for the current `sift auto` session.

    Reads SIFT_DEADLINE_TS / SIFT_DEADLINE_START_TS from env. Outside a
    timed session, prints a short notice and exits 0."""
    raw_end = os.environ.get("SIFT_DEADLINE_TS")
    raw_start = os.environ.get("SIFT_DEADLINE_START_TS")
    if not (raw_end and raw_start):
        click.echo("no deadline set for this session — pace yourself normally")
        return
    end = int(raw_end)
    start = int(raw_start)
    now = int(_time.time())
    total = max(1, end - start)
    remaining = end - now
    frac = remaining / total

    if remaining <= 0:
        phase = "overrun"
        guidance = (
            "deadline passed — write report.md immediately if you haven't, "
            "then stop. Don't open new threads."
        )
    elif frac < 0.10:
        phase = "wrap-up"
        guidance = (
            "write report.md now. Finish the current tool call only; "
            "no new searches."
        )
    elif frac < 0.25:
        phase = "consolidate"
        guidance = (
            "stop opening new threads. Tie up loose ends and start drafting "
            "report.md."
        )
    elif frac < 0.50:
        phase = "deepen"
        guidance = (
            "no big new directions. Pursue the strongest existing leads "
            "to a useful depth."
        )
    else:
        phase = "explore"
        guidance = "plenty of time. Keep going deep on the question."

    rem_str = _fmt_remaining(max(0, remaining))
    click.echo(f"remaining: {rem_str}  ({phase})")
    click.echo(guidance)


def _fmt_remaining(seconds: int) -> str:
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


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
# Research tools — Click subcommands with POSIX flags + a single positional.
# The cmd_* functions in commands.py still consume an `args` dict, so each
# wrapper just packs its parsed Click params into one.
# ---------------------------------------------------------------------------


def _run_research(fn, args: dict) -> None:
    store = Store(session_db_path())
    client = make_client()
    click.echo(fn(client, store, args))


def _run_local(fn, args: dict) -> None:
    store = Store(session_db_path())
    click.echo(fn(store, args))


@cli.command("search")
@click.argument("query", nargs=-1)
@click.option("--type", "type_", default=None,
              help="emails|docs|web|people|orgs|any (default: any)")
@click.option("-l", "--limit", type=int, default=None)
@click.option("-o", "--offset", type=int, default=None)
@click.option("--collection", default=None, help="restrict to one collection id")
@click.option("--sort", default=None, help="set to 'date' for chronological order")
@click.option("--no-cache", is_flag=True, default=False,
              help="bypass the local response cache")
@click.option("--emitter", default=None, help="alias of a Person/Organization sender")
@click.option("--recipient", default=None, help="alias of a Person/Organization recipient")
@click.option("--mentions", default=None, help="alias of a party Aleph linked to the doc")
@click.option("--date-from", default=None, help="YYYY-MM-DD")
@click.option("--date-to", default=None, help="YYYY-MM-DD")
def search_cmd(query, type_, limit, offset, collection, sort, no_cache,
               emitter, recipient, mentions, date_from, date_to) -> None:
    """Search the collection for hits."""
    _run_research(cmd_search, {
        "query": " ".join(query),
        "type": type_, "limit": limit, "offset": offset,
        "collection": collection, "sort": sort, "no_cache": no_cache,
        "emitter": emitter, "recipient": recipient, "mentions": mentions,
        "date_from": date_from, "date_to": date_to,
    })


@cli.command("read")
@click.argument("alias")
@click.option("-f", "--full", is_flag=True, default=False,
              help="don't truncate body text")
@click.option("-r", "--raw", is_flag=True, default=False,
              help="dump the full FtM JSON blob")
def read_cmd(alias, full, raw) -> None:
    """Pull the full content of an entity by alias."""
    _run_research(cmd_read, {"alias": alias, "full": full, "raw": raw})


@cli.command("sources")
@click.argument("grep", nargs=-1)
@click.option("-l", "--limit", type=int, default=None)
def sources_cmd(grep, limit) -> None:
    """List Aleph collections visible to your API key."""
    _run_research(cmd_sources, {
        "grep": " ".join(grep) or None,
        "limit": limit,
    })


@cli.command("hubs")
@click.argument("query", nargs=-1)
@click.option("--collection", default=None)
@click.option("--schema", default=None, help="schema to facet over (default: Email)")
@click.option("-l", "--limit", type=int, default=None)
def hubs_cmd(query, collection, schema, limit) -> None:
    """Top emitters / recipients / mentions for entities matching a query."""
    _run_research(cmd_hubs, {
        "query": " ".join(query),
        "collection": collection,
        "schema": schema,
        "limit": limit,
    })


@cli.command("similar")
@click.argument("alias")
@click.option("-l", "--limit", type=int, default=None)
def similar_cmd(alias, limit) -> None:
    """Aleph-extracted name-variant candidates for a party entity."""
    _run_research(cmd_similar, {"alias": alias, "limit": limit})


@cli.command("expand")
@click.argument("alias")
@click.option("--property", "property_", default=None,
              help="narrow to one relation (e.g. mentions, parent)")
@click.option("-l", "--limit", type=int, default=None)
@click.option("--no-cache", is_flag=True, default=False)
def expand_cmd(alias, property_, limit, no_cache) -> None:
    """Show entities linked via FtM property refs, grouped by property."""
    _run_research(cmd_expand, {
        "alias": alias, "property": property_,
        "limit": limit, "no_cache": no_cache,
    })


@cli.command("browse")
@click.argument("alias")
@click.option("-l", "--limit", type=int, default=None)
def browse_cmd(alias, limit) -> None:
    """Filesystem-style: parent folder and siblings of an entity."""
    _run_research(cmd_browse, {"alias": alias, "limit": limit})


@cli.command("tree")
@click.argument("alias", required=False)
@click.option("--collection", default=None,
              help="render the collection's roots instead of an entity's subtree")
@click.option("--depth", type=int, default=None)
@click.option("--max-siblings", type=int, default=None)
def tree_cmd(alias, collection, depth, max_siblings) -> None:
    """Render an ASCII subtree of a folder, or a collection's top-level roots."""
    _run_research(cmd_tree, {
        "alias": alias, "collection": collection,
        "depth": depth, "max_siblings": max_siblings,
    })


@cli.command("neighbors")
@click.argument("alias")
@click.option("--direction", default=None, help="out|in|both (default: both)")
@click.option("--property", "property_", default=None,
              help="narrow to one FtM property")
@click.option("-l", "--limit", type=int, default=None)
def neighbors_cmd(alias, direction, property_, limit) -> None:
    """Show every cached edge touching an entity (local cache only)."""
    _run_local(cmd_neighbors, {
        "alias": alias, "direction": direction,
        "property": property_, "limit": limit,
    })


@cli.command("recall")
@click.option("--collection", default=None)
@click.option("--schema", default=None)
@click.option("-l", "--limit", type=int, default=None)
def recall_cmd(collection, schema, limit) -> None:
    """Summarise what's in the local cache for this vault."""
    _run_local(cmd_recall, {
        "collection": collection, "schema": schema, "limit": limit,
    })


@cli.command("sql")
@click.argument("query")
def sql_cmd(query) -> None:
    """Read-only SQL against the cache DB (mode=ro)."""
    _run_local(cmd_sql, {"query": query})


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


@cache_group.command("clear")
@click.option("--older-than-days", type=int, default=None,
              help="only delete cache entries older than N days")
def cache_clear_cmd(older_than_days: int | None) -> None:
    """Truncate the response cache (entities/aliases/edges preserved)."""
    store = Store(session_db_path())
    click.echo(cmd_cache_clear(store, {"older_than_days": older_than_days}))


# ---------------------------------------------------------------------------
# export — markdown report → HTML, alias refs → Aleph entity links
# ---------------------------------------------------------------------------

@cli.command("export")
@click.argument("src", type=click.Path(dir_okay=False, path_type=Path),
                default=None, required=False)
@click.option("--out", "-o", "dst", type=click.Path(dir_okay=False, path_type=Path),
              default=None, help="output file (default: SRC with .html extension)")
@click.option("--server", default=None,
              help="Aleph base URL for entity links (default: ALEPH_URL from vault)")
@click.option("--no-open", "no_open", is_flag=True,
              help="don't pop the rendered HTML in the default browser")
def export_cmd(src: Path | None, dst: Path | None, server: str | None,
               no_open: bool) -> None:
    """Render report.md → report.html, turning every r-alias into a proper
    link to the entity on its Aleph server. With no SRC, exports the
    current session's report (cwd if it has one, else the most recently
    modified session under $ALEPH_SESSION_DIR)."""
    if src is None:
        src = _resolve_current_session_report()
    elif not src.exists():
        raise CommandError(f"no such file: {src}")

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

    if not no_open:
        import webbrowser
        webbrowser.open(dst.resolve().as_uri())


def _resolve_current_session_report() -> Path:
    """Pick the right report.md when the user didn't name one. cwd wins if
    it has one (covers `sift export` run inside a session dir or under
    `sift auto`); otherwise fall back to the most recently modified
    session under $ALEPH_SESSION_DIR."""
    cwd_report = Path("report.md")
    if cwd_report.exists():
        return cwd_report

    base = os.environ.get("ALEPH_SESSION_DIR")
    if not base:
        vault = make_vault()
        mp = vault.find_mount()
        if mp:
            base = str(mp / "research")
    if not base:
        raise CommandError(
            "no report.md in cwd and no session dir to search",
            "cd into a session dir, pass an explicit path, or unlock the vault",
        )

    candidates = sorted(
        Path(base).glob("*/report.md"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise CommandError(
            f"no report.md found under {base}",
            "run `sift auto \"...\"` to create one, or pass an explicit path",
        )
    return candidates[0]


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
