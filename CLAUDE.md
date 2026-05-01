# sift

Native macOS tool for investigating subjects in Aleph / OpenAleph, plus a self-driving agent mode (`sift auto`) built on the [`pi`](https://www.npmjs.com/package/@mariozechner/pi) harness. Same command surface for humans and agents. Swift implementation; Python predecessor lived under `src/sift/` and was removed when the Swift port reached parity.

## Vault & credentials

`~/.sift/` (vault sparseimage, run-state JSON, models, pi config), `/Volumes/sift-vault-*` (the mounted volume), and the `eco.datadesk.sift` Keychain service are blocked by `.claude/hooks/vault-guard.sh`. The hook also denies any Bash invocation of the sift CLI that doesn't pin `SIFT_HOME` to a sandbox path — running `sift project show` against the real home leaks live investigation context. If a task genuinely needs vault contents, ask the user to run the command themselves and paste back what's safe to share. Don't `sift auto` against a real subject from this repo.

## Project shape

- Swift 5.10, single SPM package at `Package.swift`. macOS 14+ on Apple Silicon.
- Three targets: **`SiftCore`** (library; pure logic, no UI), **`sift`** (CLI executable, target `SiftCLI`), **`sift-menubar`** (LSUIElement SwiftUI app, target `SiftMenuBar`, copied into `Sift.app/Contents/MacOS/Sift` by `make bundle`).
- The menu bar product is named `sift-menubar` deliberately — `/Users` is case-insensitive on stock APFS, so `Sift` and `sift` would collide in `.build/release/`.
- Dependencies: `swift-argument-parser` (CLI parsing), `swift-markdown` (HTML export AST). SQLite via the system `SQLite3` shim.
- Vault logic in `SiftCore/VaultService.swift` (hdiutil sparseimage + Touch ID gate). Don't refactor without a clear reason — a regression here leaks credentials. Passphrase lives in Keychain, not on disk.
- The agent's bundled `SKILL.md` and `AGENTS.md` ship as Swift target resources via `.copy("Resources")` — `sift/SKILL.md` keeps its subdirectory layout because pi requires the `--skill` directory name to match the skill name.

## Working in this repo

- Build: `make build` (CLI + signed app bundle) or `swift build -c release --product sift` for just the CLI.
- Install to `~/.local/bin` + `/Applications`: `make install`. Pi is installed locally to `~/Library/Application Support/Sift/pi/` (no npm globals); `Paths.findExecutable("pi")` checks there first, then `$PATH`.
- Wipe the install: `make uninstall` (keeps the user's vault state under `~/.sift/`).
- Tests live in `Tests/SiftCoreTests/` (XCTest). They compile under Xcode but `swift test` won't work on a Command Line Tools-only host — XCTest isn't shipped. Run them via Xcode or a CI runner with full Xcode.
- Every CLI smoke test must use `SIFT_HOME=/tmp/something` — see the feedback memory.
- The agent voice in `Resources/AGENTS.md` and `Resources/sift/SKILL.md` is deliberately neutral / wire-service. Don't loosen it when editing prompts.

## Key invariants

- **Aliases (`r1`, `r2`, …) are stable across sessions on a vault.** `aleph.sqlite` lives at `<vault>/research/aleph.sqlite` and is shared. `Session.dbPath()` resolves to that path when neither `ALEPH_DB_PATH` nor a different `ALEPH_SESSION_DIR` is set; PiRunner.prepare deliberately does NOT override `ALEPH_DB_PATH` so the share is preserved.
- **Detached `sift auto` is the default for headless prompts.** The CLI re-execs into a hidden `_daemon` subcommand via `posix_spawnp + POSIX_SPAWN_SETSID`, returns to the shell, and the daemon writes a per-session log + run-state JSON the menu bar app watches. Foreground REPL (no prompt) execs into pi directly.
- **All secrets live in macOS Keychain** under service `eco.datadesk.sift` (vault passphrase, Aleph URL/key, hosted-backend key). Never write secrets to disk.
- **`sift sql` is read-only.** Connection is opened with `SQLITE_OPEN_READONLY`; we explicitly step write-side statements so SQLite reports `SQLITE_READONLY` rather than silently no-oping.
