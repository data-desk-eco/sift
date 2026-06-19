# sift architecture

A short tour for contributors. CLAUDE.md has the load-bearing
invariants in checklist form; this file is the *narrative* — how the
parts fit and why the moving parts move.

## Two targets, one library

```
Sources/
  SiftCore/          ← pure logic; library; no UI deps
  SiftCLI/           ← `sift` binary; uses ArgumentParser + SiftCore
```

`SiftCore` knows nothing about CLI parsing. The CLI is thin glue over
it. sift is a CLI only — a SwiftUI menu-bar app once lived here and was
removed; it earned nothing the terminal didn't already give.

## The two storage tiers

```
~/.sift/                              ← unencrypted operational state
  backend.json                        ← which LLM (local llama / hosted)
  llama-server.{log,pid}              ← lifecycle for the local model
  models/Qwen3.6-…gguf                ← downloaded model weights
  pi/                                 ← pi-coding-agent config
  log/sift.log                        ← structured log
  .vault.sparseimage                  ← AES-256 encrypted volume

/Volumes/sift-vault-<hash>/           ← mount of the sparseimage
  secrets.json                        ← Aleph + hosted-backend credentials
  research/
    aleph.sqlite                      ← shared cache (entities, aliases, edges)
    <run>/                            ← one dir per `sift auto` brief
      leads.txt                       ← the worklist (run state)
      segments/<slug>-<hash>.md       ← one lead's write-up (one file per lead)
      report.md                       ← final write-up, stitched from segments
```

Two clear separations:
- **Operational state** in `~/.sift/` (no secrets, no investigation
  contents). Survives vault unmount.
- **Everything sensitive** on the encrypted volume — secrets, research
  outputs, the response cache, alias assignments. Mounted only after
  the user types the vault passphrase. The passphrase is chosen at
  `sift init`, never persisted by sift, and prompted once per boot via
  `requireVault()` — losing it is unrecoverable.

## The sweep: plan → sweep → report

`sift auto BRIEF` is the headline command. It's a synchronous run —
no daemon, no detachment, no sidecar, no in-Swift agent loop (all
removed). The local model slows badly once a context passes a few tens
of thousands of tokens, so the design goal is simple: never let one
agent's context grow without bound. The run does that by giving every
unit of work a fresh `pi` *process* and keeping the accumulated state on
disk instead of in the context window — the new process per lead **is**
the entire context-management strategy (no compaction, no deadline, no
digest, no salvage).

`Sources/SiftCLI/Commands/Auto.swift` is a thin launcher: it unlocks the
vault, calls `PiRunner.prepare` (start llama, configure the backend,
build the system prompt, assemble the env), then `exec`s the bundled
`Resources/orchestrate.sh <run-dir> <brief>` with `PI_BIN` / `SIFT_SKILL`
/ `SIFT_SYSTEM_PROMPT` set and the executable dir on `PATH` (so the
agent's own `sift …` resolves). The script spawns one fresh
`pi --no-session -p --mode json` session per phase and per lead, each
piped through `sift render` — a hidden command that turns pi's JSON
event stream into readable stdout lines via `EventStream`.

```
user types `sift auto sanctions.md`
       │
       ▼
  Auto.swift: unlock vault, PiRunner.prepare, exec orchestrate.sh
  run dir = <vault>/research/<brief-basename>/
       │
       ▼
  (0) plan (if leads.txt absent)  one agent reads the brief and queues a
                                  worklist via `sift queue` → leads.txt
       │
       ▼
  (1) sweep: for each pending lead in leads.txt
        fresh `pi … | sift render`   a new process per lead — independent
                                     context; searches, records facts with
                                     `sift note`, queues new leads
        done when segments/<slug>-<hash>.md exists   (loop dedups/resumes
                                     by segment existence; an empty lead
                                     gets an honest stub so it's not retried)
       │
       ▼
  (2) report   a final session stitches the segments into report.md
       │
       ▼
  Auto.execute: LlamaServer.stopLocal()   reap the model on a clean finish
```

`leads.txt` is the entire mutable run state. A line is pending unless
it's blank, a `#` comment, or already `✓`-marked. Any agent grows the
sweep by calling `sift queue "<lead>"`, which appends to the worklist
(`Sources/SiftCore/Worklist.swift`). Per-lead agents only search and
write prose, citing source aliases inline; one pi runs at a time, so
there are no concurrent writers. The per-phase prompts and their
wire-service style rules live in `orchestrate.sh`, off the always-loaded
system prompt. There is no findings / FtM-entity store — `report.md` is
the sole deliverable.

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
  `similar`, `hubs`, `sources`, `recall`, `sql`, `cache`, `time`,
  `report`, `note`, `queue`.
- **Off-limits to the agent:** `init`, `vault *`, `backend *`,
  `project *`, `auto`. Touching these from inside a sweep would prompt
  for the vault passphrase or fork another sweep.

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

- `make build` — the CLI.
- `make install` — drops the CLI in `~/.local/bin` and pi in
  `~/Library/Application Support/Sift/`.
- `make release` — produces a self-contained, CLI-only `Sift.app` (the
  CLI is the bundle executable; pi bundled inside), zipped for GitHub
  Release upload so the Homebrew cask can ship both as one artefact.
- Cutting a release: bump `Sources/SiftCore/SiftCore.swift::version`,
  tag `v<X.Y.Z>`, push. `release.yml` builds, attaches the zip, and
  (if `TAP_PAT` is set) opens a PR against `data-desk-eco/homebrew-tap`
  bumping `Casks/sift.rb`.

## Where to look first

- **A new agent-facing tool?** Add a function under
  `Sources/SiftCore/Commands/` and a CLI wrapper in
  `Sources/SiftCLI/Commands/Research.swift`. Document in
  `Sources/SiftCLI/Resources/sift/SKILL.md`.
- **The agent loop / sweep behaviour?** `Sources/SiftCLI/Commands/Auto.swift`
  (orchestration) and `Sources/SiftCore/PiRunner.swift` (one pi run).
  Run state is the worklist file + `Sources/SiftCore/Worklist.swift`.
