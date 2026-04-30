"""sift's data-tool implementation, broken out as an importable package
so each concern (HTTP client, vault, store, render, commands) lives in
its own file. Entry point is `tool.cli:main`, invoked by the thin
`bin/sift-tool` uv inline-script shim."""
