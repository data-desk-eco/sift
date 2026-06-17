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
    <run>/                            ← one dir per `sift auto` sweep
      report.md                       ← running narrative (shared)
      findings.db                     ← FtM findings (shared across the sweep)
      digest.md                       ← periodic consolidation
      pi.stderr.log                   ← raw pi stderr (rotated)
      .pi-sessions/<topic>/           ← pi's per-topic conversation history
```

Two clear separations:
- **Operational state** in `~/.sift/` (no secrets, no investigation
  contents). Survives vault unmount.
- **Everything sensitive** on the encrypted volume — secrets, research
  outputs, the response cache, alias assignments. Mounted only after
  the user types the vault passphrase. The passphrase is chosen at
  `sift init`, never persisted by sift, and prompted once per boot via
  `requireVault()` — losing it is unrecoverable.

## The topic sweep

`sift auto LIST.txt` is the headline command. It's a synchronous loop
— no daemon, no detachment, no sidecar (all removed). The local model
slows badly once a context passes a few tens of thousands of tokens, so
the design goal is simple: never let one agent's context grow without
bound. The sweep does that by giving every topic a fresh, short-lived
agent and keeping the accumulated state on disk instead of in the
context window.

The flow (`Sources/SiftCLI/Commands/Auto.swift`):

```
user types `sift auto sanctions.txt`
       │
       ▼
  ensure vault unlocked; run dir = <vault>/research/<list-basename>/
       │
       ▼
  while Worklist.next(at: list):                      ← first un-marked line
    PiRunner.prepare    starts llama-server (recycling any stale one),
                        writes pi config + system prompt; legSubdir =
                        t<n>-<slug> → a fresh pi context per topic
    PiRunner.drivePi    spawns pi with the topic prompt + --mode json;
                        EventStream renders events to stderr (live)
    Worklist.markDone   prefixes the line with `✓` (re-reads first, so
                        topics the agent queued mid-run survive)
    every 3 topics:     a consolidation pass writes digest.md, which is
                        prepended to later topics' prompts
  LlamaServer.stopLocalIfIdle    reap the model when the sweep ends
```

The worklist file is the entire run state. A line is pending unless
it's blank, a `#` comment, or already `✓`-marked. The agent grows the
sweep by calling `sift queue "<lead>"`, which appends to the file named
in `$SIFT_TOPIC_LIST` (`Sources/SiftCore/Worklist.swift`). `report.md`
and `findings.db` live in the run dir and are shared across every topic,
so findings accumulate and dedupe against the shared `aleph.sqlite`
alias table. There are no concurrent writers — one pi runs at a time,
and the orchestrator only touches the worklist between sessions.

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
  `report`, `entity`, `queue`.
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
