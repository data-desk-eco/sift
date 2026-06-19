# Changelog

All notable changes to sift land here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

## [0.1.4] — 2026-06-19

### Changed
- `sift queue` and `sift note` are hidden from `sift --help` — they're
  plumbing for the sweep (`orchestrate.sh`) and the agent (documented in
  the bundled `SKILL.md`), not commands a human types, so the human CLI
  surface no longer advertises them (same treatment as the hidden
  `render`). Both still work when called directly.

## [0.1.3] — 2026-06-19

Reworked `sift auto` from a single long-running agent into a bash-driven
**lead sweep**, and stripped the scaffolding that supported the old model.

### Changed
- `sift auto BRIEF` is now a synchronous plan → sweep → report run
  orchestrated by a bundled `orchestrate.sh`. **Plan** turns the brief
  into a `leads.txt` worklist via `sift queue`; **sweep** spawns one
  fresh `pi --no-session` session per lead — the new process per lead is
  the entire context-management strategy, so the local model never drags
  a prior lead's context forward (the slowdown that made long runs
  unusable on a laptop); **report** stitches the per-lead segments into
  `report.md`. Re-running resumes by segment existence.
- Per-lead agents write their findings up as markdown segments under
  `segments/` (one append per fact via `sift note`), citing the source
  alias for every claim, instead of recording FollowTheMoney entities.
  The prompts and bundled `SKILL.md` / `AGENTS.md` were slimmed to that
  core loop; report-style rules live in the final phase's prompt.
- `llama-server` is reused if already healthy on the port (skipping a
  multi-second model reload, including across `^C`'d runs) and reaped on
  a clean finish.

### Added
- `sift queue "<lead>"` — any agent appends freshly surfaced leads to the
  worklist for a later session to pick up; the planner uses it too.
- `sift note "<prose>"` — appends a fact to the current lead's segment.
- `sift render` — turns pi's JSON event stream into readable stdout lines
  (used to pipe each phase's output to the terminal).

### Removed
- The FollowTheMoney findings store and the `sift entity` command family
  (`findings.db`, `FindingsStore`, `Ftm`). The report is the sole
  deliverable now; nothing consumed the structured store downstream.
- The SwiftUI menu-bar app and its App Intent.
- The detached `_daemon` re-exec, `.sift-run.json` sidecars, the active
  lead, the in-Swift agent loop, and the `lead` / `status` / `logs` /
  `stop` commands. Runs are foreground now; ^C stops a sweep.

## [0.1.0] — 2026-05-06

Initial public release. Native macOS investigation tool for Aleph
/ OpenAleph with an optional self-driving agent mode (`sift auto`)
built on the `pi-coding-agent` harness. Distributed as a Homebrew
cask; the `Sift.app` bundles the CLI, the agent harness, and a
SwiftUI menu-bar UI that surfaces live agent runs and exposes an
App Intent for Shortcuts / Siri / Raycast.

### Storage and credentials
- AES-256 encrypted vault (hdiutil sparseimage) holds Aleph and
  hosted-backend credentials, the shared response cache, alias
  assignments, and per-session research outputs.
- Passphrase-only unlock: the user picks a passphrase at `sift
  init`, sift never persists it, and `requireVault()` prompts for
  it once per boot. Losing it is unrecoverable.
- Operational state in `~/.sift/` (no secrets, no investigation
  contents) survives vault unmount.

### Agent loop
- `sift auto "PROMPT"` detaches into a hidden `_daemon` subcommand
  via `posix_spawnp + POSIX_SPAWN_SETSID`, returns to the shell,
  and writes a per-session log + `.sift-run.json` sidecar inside
  the session directory.
- "Active lead" persists a single pinned session in
  `~/.sift/active-lead`; `sift logs`, `sift attach`, `sift stop`,
  and `sift status` default to it.
- `llama-server` is reaped when no agent run is using it, freeing
  ~14 GB of unified memory between sessions.
- `RunRegistry` writes per-event progress that the menu-bar app
  watches via `DispatchSource` and surfaces as native
  `UNUserNotification`s on session transitions.

### CLI surface
- Agent-safe research commands (documented in the bundled
  SKILL.md): `search`, `read`, `expand`, `browse`, `tree`,
  `similar`, `hubs`, `sources`, `recall`, `sql`, `cache`, `time`.
- Operator commands (off-limits to the agent): `init`, `vault *`,
  `backend *`, `project *`, `auto`, `lead`, `status`, `logs`,
  `attach`, `stop`, `export`.
- `sift sql` is read-only — connection opened with
  `SQLITE_OPEN_READONLY`; write-side statements report
  `SQLITE_READONLY` rather than silently no-oping.
- Aliases (`r1`, `r2`, …) are stable across every session on a
  vault — the shared `aleph.sqlite` makes `r5` resolve to the same
  entity weeks later, so an agent's report citing `r12` can be
  reread by a human or another run.

### Reliability
- `AlephClient.RetryPolicy`: automatic retry on 429 (honoring
  `Retry-After`) and 5xx with exponential backoff. Default 4
  attempts, 1 s base, 30 s cap; transient `URLError`s are retried
  on the same curve.
- `RotatingLog`: single-generation size-capped rotation (default
  10 MB) on `auto.log`, `pi.stderr.log`, `llama-server.log`, and
  `~/.sift/log/sift.log`, so long agent runs don't fill the vault.
- `scanSubtree` fetches up to 4 pages of Aleph results in parallel
  and ingests each page in a single SQLite transaction, so 200
  entities cost roughly one fsync rather than 200.
- `SessionName` strict allow-list validator gates every consumer
  that turns a session name into a filesystem path, so a corrupted
  `~/.sift/active-lead` or a hand-crafted run-state JSON cannot
  escape `~/.sift/run/`.
- `AlephClient.init` rejects non-http(s) URL schemes;
  `Backend.resolveRedirect` refuses non-https model-download
  targets.
- `PiRunner` caps line buffers at 4 MiB so a runaway pi event line
  can't OOM the daemon.

### Build and distribution
- Three SPM targets: `SiftCore` (pure logic), `sift` (CLI), and
  `sift-menubar` (LSUIElement SwiftUI app, copied into
  `Sift.app/Contents/MacOS/Sift` by `make bundle`).
- `make build` produces an ad-hoc-signed app; `make release`
  builds the self-contained zip the GitHub Release workflow
  attaches.
- `release.yml` builds the bundle, attaches the zip to the
  GitHub release, and (if `TAP_PAT` is set) opens a PR against
  `data-desk-eco/homebrew-tap` bumping `Casks/sift.rb`.
- 165 tests pass via `make test` in ~290 ms using swift-testing —
  Command Line Tools is enough, no Xcode required.
