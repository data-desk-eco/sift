# sift

Native macOS tool for investigating subjects in Aleph / OpenAleph, plus a self-driving agent mode (`sift auto`) built on the [`pi`](https://www.npmjs.com/package/@mariozechner/pi-coding-agent) harness. Same command surface for humans and agents. Swift implementation; Python predecessor lived under `src/sift/` and was removed when the Swift port reached parity.

## Vault & credentials

`~/.sift/` (vault sparseimage, models, pi config) and `/Volumes/sift-vault-*` (the mounted volume, which holds `secrets.json` with Aleph + hosted-backend creds) are blocked by `.claude/hooks/vault-guard.sh`. The hook also denies any Bash invocation of the sift CLI that doesn't pin `SIFT_HOME` to a sandbox path — running `sift project show` against the real home leaks live investigation context. If a task genuinely needs vault contents, ask the user to run the command themselves and paste back what's safe to share. Don't `sift auto` against a real subject from this repo.

## Project shape

- Swift 5.10, single SPM package at `Package.swift`. macOS 14+ on Apple Silicon.
- Two targets: **`SiftCore`** (library; pure logic, no UI) and **`sift`** (CLI executable, target `SiftCLI`). sift is a CLI only — there's no GUI. (A SwiftUI menu-bar app once shipped here; it was removed because it earned nothing over the terminal.)
- Dependencies: `swift-argument-parser` (CLI parsing), `swift-markdown` (HTML export AST). SQLite via the system `SQLite3` shim.
- Vault logic in `SiftCore/VaultService.swift` (hdiutil sparseimage). Don't refactor without a clear reason — a regression here leaks credentials. The user picks the passphrase at `sift init`; sift never persists it. Every command that needs vault contents prompts for it once per boot via `requireVault()` in `SiftCLI/VaultPrompt.swift`, then reuses the existing `/Volumes/sift-vault-*` mount.
- The agent's bundled `SKILL.md` and `AGENTS.md` ship as Swift target resources via `.copy("Resources")` — `sift/SKILL.md` keeps its subdirectory layout because pi requires the `--skill` directory name to match the skill name.

## Working in this repo

- Build: `make build` (CLI) or `swift build -c release --product sift` — same thing now there's no app bundle.
- Dev install to `~/.local/bin`: `make install`. Pi goes to `~/Library/Application Support/Sift/pi/`.
- Production install (what users actually run): `brew install --cask data-desk-eco/tap/sift`. The cask in `data-desk-eco/homebrew-tap` points at a release zip built by `.github/workflows/release.yml`; the resulting `Sift.app` is a CLI-only bundle (no GUI process) with the CLI at `Contents/Resources/bin/sift` and pi at `Contents/Resources/pi/`. `Paths.findExecutable` walks up from `Bundle.main` to find the .app and prefers in-bundle tooling, falling back to the support-dir layout for dev installs.
- Cut a release: bump `Sources/SiftCore/SiftCore.swift` `version`, commit, `git tag v<X.Y.Z>`, `git push --tags`. The workflow builds the bundle, attaches the zip to the release, and (if `TAP_PAT` secret is set) opens a PR against `data-desk-eco/homebrew-tap` bumping `Casks/sift.rb`. Locally: `make release` produces the same artefact under `.build/release-bundle/`.
- Wipe the dev install: `make uninstall` (keeps the user's vault state under `~/.sift/`).
- Tests live in `Tests/SiftCoreTests/` and use [swift-testing](https://github.com/swiftlang/swift-testing) (pulled as an SPM dep so it works on Command Line Tools alone — no Xcode needed). Run with `make test` — `swift test` directly hangs on a parallelism race in our suite, and `make test` runs them serially.
- Every CLI smoke test must use `SIFT_HOME=/tmp/something` — see the feedback memory.
- The agent voice in `Resources/AGENTS.md` and `Resources/sift/SKILL.md` is deliberately neutral / wire-service. Don't loosen it when editing prompts.

## Key invariants

- **Aliases (`r1`, `r2`, …) are stable across sessions on a vault.** `aleph.sqlite` lives at `<vault>/research/aleph.sqlite` and is shared. `Session.dbPath()` resolves to that path when neither `ALEPH_DB_PATH` nor a different `ALEPH_SESSION_DIR` is set; PiRunner.prepare deliberately does NOT override `ALEPH_DB_PATH` so the share is preserved.
- **`sift auto LIST.txt` is a synchronous topic sweep.** No daemon, no detachment, no sidecar, no active-lead state — those were all removed. `Sources/SiftCLI/Commands/Auto.swift` reads a worklist file (one topic per line), and for each pending line boots one foreground pi session via `PiRunner.prepare` + `PiRunner.drivePi` (pi runs `-p --mode json`; events stream to stderr). Each topic gets a fresh pi context (`legSubdir = t<n>-<slug>`, `resuming: false`) so qwen never drags a prior topic's context forward — that bounded-context discipline is the whole point of the rewrite. `report.md` + `findings.db` live in the run dir (`<vault>/research/<list-basename>/`) and are **shared across every topic in the sweep**, so findings accumulate. The worklist file is the only run state: pending lines are un-marked, done lines get a leading `✓`, and the agent appends new leads with `sift queue` (which writes to `$SIFT_TOPIC_LIST`). Every `consolidateEvery` (3) topics a `digest.md` pass synthesises progress, and the digest is prepended to later topics' prompts.
- **CLI surface is split between agent and human.** The bundled SKILL.md only documents the agent-safe commands (search/read/expand/browse/tree/similar/hubs/sources, plus recall/sql/cache stats/time/report, plus the findings DB and `sift queue`). Setup + run commands (`init`, `vault`, `backend`, `project`, `auto`) are explicitly off-limits to the agent — invoking them from inside a sweep would trigger Touch ID prompts or fork another sweep.
- **All secrets live inside the encrypted vault** at `<vault>/secrets.json` (Aleph URL/key, hosted-backend URL/key/model). The vault passphrase is prompted from the user on first use after a reboot and never persisted — losing it is unrecoverable. Aleph creds are injected into the agent's environment as `ALEPH_URL` / `ALEPH_API_KEY` by `PiRunner.prepare`; the agent must never open `secrets.json` directly.
- **`sift sql` is read-only.** Connection is opened with `SQLITE_OPEN_READONLY`; we explicitly step write-side statements so SQLite reports `SQLITE_READONLY` rather than silently no-oping.
- **llama-server is reaped at the end of a sweep.** `LlamaServer.stopLocalIfIdle()` (now an unconditional `stopLocal`) is called once `auto`'s topic loop finishes — leaving the model up pins ~14 GB of unified memory and the rest of the Mac feels sluggish. Because runs are synchronous there's never a second concurrent user; `LlamaServer.start()` recycles any server already on the port so each topic gets a clean, fast boot rather than inheriting a slow KV-cache-laden one.
