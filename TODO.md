# TODO

## Investigate parallel test deadlock

Running bare `swift test` (no flags) hangs indefinitely on macOS 26.2 with
Swift Testing 0.12 — every cooperative dispatch thread blocks on
`_dispatch_group_wait_slow`, originating in `AlephClient`'s
`DispatchSemaphore.wait` inside its URLSession callback path.

`swift test --no-parallel` and `make test` (which already passes
`--no-parallel`) complete the full 161-test suite in ~200 ms. CI uses
`--no-parallel` too, so this doesn't gate releases — but `swift test` is
the obvious thing to type and it should not hang.

Likely fix: replace the synchronous `URLSession + DispatchSemaphore` pattern
in `AlephClient` (and `Backend.healthCheck` / `Backend.resolveRedirect`)
with `await URLSession.data(for:)`, then drop the `.serialized` suite
trait. Until then, run tests via `make test` or `swift test --no-parallel`.
