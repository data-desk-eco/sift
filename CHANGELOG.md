# Changelog

All notable changes to sift land here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `RotatingLog` — single-generation size-capped rotation (default 10 MB)
  applied to `auto.log`, `pi.stderr.log`, `llama-server.log`, and
  `~/.sift/log/sift.log`. Long agent runs no longer fill the vault.
- `AlephClient.RetryPolicy` — automatic retry on 429 (honoring
  `Retry-After`) and 5xx with exponential backoff. Default: 4 attempts,
  1 s base, 30 s cap. Transient `URLError`s are also retried.
- `SessionName` — strict allow-list validator gating every consumer
  that turns a session name into a filesystem path. Closes a
  defence-in-depth gap where a corrupted `~/.sift/active-lead` or a
  hand-crafted run-state JSON could escape `~/.sift/run/`.
- `Log.say(_:_:)` — central helper for `[scope]   message` stderr
  lines, replacing 15+ open-coded `FileHandle.standardError.write`
  call sites.
- `Sift.shellQuote(_:)` — single source of truth for POSIX-safe shell
  quoting; replaces two duplicate implementations.
- `SiftSubcommand` protocol — funnels every CLI command's error
  handling through one place. Subcommands implement `execute()`
  instead of `run()`. Eliminated 33 instances of the
  `do { ... } catch { throw ExitCode(reportSiftError(error)) }`
  boilerplate.
- `ARCHITECTURE.md` — narrative tour of the codebase for contributors.
- `make test` target and `.github/workflows/ci.yml` for PR-time build
  + test verification.
- Tests: migrated from XCTest to swift-testing so the suite runs on
  Command Line Tools alone — no Xcode required. Added test files for
  `SessionName`, `RotatingLog`, `AlephClient` (retry/backoff with
  stubbed `URLProtocol`), `Log.say`, `ActiveLead`, `Session.dbPath`,
  `RunRegistry`, `SystemPrompt`, `PiRunner.resolveSession` and
  helpers, `Sift.shellQuote`, `SiftError`, `Subprocess` (run/check/which
  against real `/bin` binaries), `Backend.Config` (read/write/codable),
  and the full `Commands/*` layer (`runSearch`, `runRead`, `runExpand`,
  `runHubs`, `runSimilar`, `runSources`, `runBrowse`, `runTree`,
  `runRecall`, `runSQL`, `runCacheStats`/`runCacheClear`,
  `runNeighbors`) using stubbed Aleph responses. 159 tests, ~280 ms.
  Line coverage of `SiftCore`: 26% → 61%.

### Changed
- `AlephClient.init` now throws if the URL scheme isn't http/https.
  Defence-in-depth against a `file://` URL stored in Keychain
  exfiltrating local files.
- `BackendHosted` validates URL scheme before issuing the endpoint
  health check.
- `Backend.resolveRedirect` refuses non-https model-download targets,
  blocking a downgrade attack on the model fetch.
- `Backend.startLocal` kills the orphan process and removes the
  pidfile if the readiness health check times out, so a retry isn't
  blocked by a stale port collision.
- `VaultService.initialize` no longer returns the passphrase. Callers
  never used it; not handing it back removes a footgun and keeps the
  passphrase out of caller stack frames.
- `RunRegistry.update` now refuses to overwrite a `.stopped` status
  with `.failed`, so a SIGTERM-driven `sift stop` reads as "stopped"
  rather than "failed".
- `RunRegistry.read` validates the decoded session name against
  `SessionName.isValid`, treating malformed or hostile JSON files as
  not-found.
- `PiRunner` line-buffer cap (4 MiB) so a runaway pi event line can't
  OOM the daemon.
- `Subprocess.which` is now pure-Swift PATH walk — no fork/exec.
- `RunStateModel.tailLog` writes to `~/.sift/tail/<session>.command`
  rather than littering `/tmp` on every click.
- `sift vault init` output explains where the passphrase lives, that
  it's device-only, and how to back it up via Keychain Access.app.

### Fixed
- `VaultService.randomPassphrase` now throws on RNG failure rather
  than silently producing a zero-byte passphrase.
- `Deadline.parseDuration` — removed a tautological guard that did
  nothing.
- `Sift.entitlements` — dropped redundant/mislabeled keys
  (`app-sandbox=false` was the default, `smartcard=false` was
  incorrectly captioned "Touch ID"). Kept only the two load-bearing
  hardened-runtime exceptions needed for pi's Node dylibs.

## [0.1.0] — 2026-05-01

Initial public release. Native macOS investigation tool for Aleph /
OpenAleph with optional self-driving agent mode. Encrypted vault,
Keychain-stored credentials, menu bar app with App Intent for
Shortcuts / Siri / Raycast, Homebrew cask distribution.
