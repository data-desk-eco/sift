# sift architecture

A short tour for contributors. CLAUDE.md has the load-bearing
invariants in checklist form; this file is the *narrative* — how the
parts fit and why the moving parts move.

## Three targets, one library

```
Sources/
  SiftCore/          ← pure logic; library; no UI deps
  SiftCLI/           ← `sift` binary; uses ArgumentParser + SiftCore
  SiftMenuBar/       ← `Sift` menu-bar app; SwiftUI + AppKit + SiftCore
```

`SiftCore` knows nothing about CLI parsing or AppKit. The CLI and the
menu-bar app are thin glue. This split is enforced by the SPM target
graph: trying to import AppKit into Core won't compile.

## The two storage tiers

```
~/.sift/                              ← unencrypted operational state
  active-lead                         ← name of the user's pinned session
  backend.json                        ← which LLM (local llama / hosted)
  llama-server.{log,pid}              ← lifecycle for the local model
  models/Qwen3.6-…gguf                ← downloaded model weights
  pi/                                 ← pi-coding-agent config
  run/<session>.json                  ← daemon run-state per session
  tail/<session>.command              ← ephemeral terminal-launch scripts
  log/sift.log                        ← structured log
  .vault.sparseimage                  ← AES-256 encrypted volume

/Volumes/sift-vault-<hash>/           ← mount of the sparseimage
  secrets.json                        ← Aleph + hosted-backend credentials
  research/
    aleph.sqlite                      ← shared cache (entities, aliases, edges)
    <session>/
      report.md                       ← agent-written investigation
      findings.db                     ← structured extractions
      auto.log, pi.stderr.log         ← per-session logs (rotated)
      .pi-sessions/                   ← pi's conversation history
```

Two clear separations:
- **Operational state** in `~/.sift/` (no secrets, no investigation
  contents). Survives vault unmount.
- **Everything sensitive** on the encrypted volume — secrets, research
  outputs, the response cache, alias assignments. Mounted only after
  the user types the vault passphrase. The passphrase is chosen at
  `sift init`, never persisted by sift, and prompted once per boot via
  `requireVault()` — losing it is unrecoverable.

## The detached-daemon dance

`sift auto "PROMPT"` is the headline command. It needs to:

1. Return to the shell promptly (the user doesn't want to babysit a
   30-minute agent run).
2. Survive the parent shell's exit, SIGHUP on terminal close, etc.
3. Stream live progress somewhere visible (menu bar app, `sift logs -f`).
4. Reap the local llama-server when no run is using it.

The flow:

```
user types `sift auto "investigate X"`
       │
       ▼
  AutoCommand resolves session, ensures vault unlocked, picks lead vs new
       │
       ▼
  posix_spawnp the same binary with `_daemon` subcommand,
  fd 0/1/2 → /dev/null, POSIX_SPAWN_SETSID
       │
       ├─→ parent prints "[auto]   started <session> (pid …)" and exits
       │
       ▼
  child (DaemonRunCommand):
    PiRunner.prepare       starts llama-server (if local), writes pi config
    pi.run()               spawns pi-coding-agent with prompt + --mode json
    EventStream.ingest()   filters pi's JSON event stream
    RunRegistry.update*    writes per-event state to ~/.sift/run/<s>.json
    pi exits
    Backend.stopLocalIfIdle  reaps llama-server if no other run is live
    RunRegistry final write  status = .finished/.failed/.stopped
```

Concurrent writers to `<session>.json`:
- The daemon writes per-event progress (`updateIfRunning` so it can't
  clobber a `.stopped` mid-flight).
- `sift stop` writes `.stopped` directly.
- The daemon's exit handler preserves an existing `.stopped` rather
  than overwriting with `.failed` when SIGTERM-killed pi exits non-zero.

The menu bar app watches `~/.sift/run/` via `DispatchSource` (with a
2-second poll fallback) and re-reads on every change. It posts a
native `UNUserNotification` when it sees a session transition out of
`.running`.

## Active lead

A "lead" is the user's pinned investigation. `~/.sift/active-lead`
holds one session name. Every fresh `sift auto` sets it; every
follow-up command (`logs`, `attach`, `stop`, `status`'s `*` marker)
defaults to it. The user clears it with `sift lead --clear` to revert
to "most recent" semantics.

This is the single biggest UX win in the tool: typing `sift logs`
reliably tails *the* investigation rather than whichever ran last.

## Alias stability

Every Aleph entity gets a short alias (`r1`, `r2`, …) on first sight,
stored in `aleph.sqlite`. Crucially, `aleph.sqlite` is **shared
across all sessions on a vault** — `r5` resolves to the same entity
in every investigation. That stability is what lets the agent's
report cite `r12` and have a human (or another agent run) read the
same source weeks later.

Implementation detail: `PiRunner.prepare` deliberately does NOT set
`ALEPH_DB_PATH`. Without it, `Session.dbPath()` resolves to
`<vault>/research/aleph.sqlite` — the shared one. Setting it would
silo each session.

## CLI / agent split

`sift --help` shows everything. The bundled `SKILL.md` (loaded by pi
when the agent starts) lists *only* the agent-safe commands:

- **Agent surface:** `search`, `read`, `expand`, `browse`, `tree`,
  `similar`, `hubs`, `sources`, `recall`, `sql`, `cache`, `time`.
- **Off-limits to the agent:** `init`, `vault *`, `backend *`,
  `project *`, `auto`, `lead`, `status`, `logs`, `attach`, `stop`,
  `export`. Touching these from inside `sift auto` would prompt for
  the vault passphrase, fork another agent, or stop the running
  session.

The agent doesn't enforce this with code — it follows the SKILL.md.
But the `vault-guard.sh` hook in `.claude/hooks/` blocks Claude Code
from invoking sift commands without a sandboxed `SIFT_HOME` during
this project's own development.

## The retry / backoff layer

`AlephClient.get` wraps requests in a retry loop:

- **429:** honors `Retry-After` (seconds or HTTP-date), capped at the
  policy's `maxBackoff`.
- **5xx:** exponential backoff (`baseBackoff * 2^attempt`).
- **Transient `URLError`** (timeout, connection lost, DNS): same
  backoff curve.
- **Auth/4xx-other:** surfaces immediately — retrying won't help.

Default policy: 4 attempts, base 1s, cap 30s. Tests inject a custom
`URLSessionConfiguration` with a `StubURLProtocol` so retry logic is
exercised without a real network.

## Build pipeline

- `make build` — CLI + ad-hoc-signed `Sift.app`.
- `make install` — drops the CLI in `~/.local/bin`, the app in
  `/Applications`, and pi in `~/Library/Application Support/Sift/`.
- `make release` — produces a self-contained `Sift.app` with the CLI
  and pi bundled inside, zipped for GitHub Release upload.
- Cutting a release: bump `Sources/SiftCore/SiftCore.swift::version`,
  tag `v<X.Y.Z>`, push. `release.yml` builds, attaches the zip, and
  (if `TAP_PAT` is set) opens a PR against `data-desk-eco/homebrew-tap`
  bumping `Casks/sift.rb`.

## Where to look first

- **A new agent-facing tool?** Add a function under
  `Sources/SiftCore/Commands/` and a CLI wrapper in
  `Sources/SiftCLI/Commands/Research.swift`. Document in
  `Sources/SiftCLI/Resources/sift/SKILL.md`.
- **A new run-management feature?** `Sources/SiftCLI/Commands/` plus
  any persisted state in `~/.sift/`. Document in `README.md` if
  user-visible; do not add to `SKILL.md`.
- **Something the menu bar app should react to?** Add to
  `RunState`, write from the daemon, surface in `RunStateModel`.
