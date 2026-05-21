import Darwin
import Foundation

/// forge-guardrails proxy lifecycle. Sits between pi and llama-server
/// on the local backend, applying rescue parsing, retry nudges, and
/// tiered context compaction. Hosted backend bypasses it entirely.
///
/// Wire format: forge speaks OpenAI `/v1/chat/completions`, same as
/// llama-server with `--jinja`. Pi is configured to hit the proxy port
/// instead of the llama port; the proxy forwards to llama-server.
///
/// Forge is a Python package; we run it via `uv run --with`, which
/// caches the env in `~/.cache/uv/`. First invocation downloads forge
/// (~few seconds); subsequent invocations reuse the cache.
public enum ForgeProxy {

    public static let defaultProxyPort = 8081
    public static let pythonVersion = "3.12"
    public static let packageSpec = "forge-guardrails"

    // MARK: - Process lifecycle

    public static func healthCheck(port: Int, timeout: TimeInterval = 1) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                ok = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        if !ok { task.cancel() }
        return ok
    }

    /// Bring the proxy up for the current backend. No-op for hosted
    /// (forge sits in front of llama-server only — hosted backends are
    /// frontier models that don't need its guardrails). Idempotent:
    /// if a healthy proxy is already on the port and another auto
    /// session is using it, reuse it.
    public static func start() throws {
        let config = try Backend.requireConfig()
        guard config.kind == .local else { return }

        let proxyPort = defaultProxyPort
        let llamaPort = config.port ?? Backend.defaultLocalPort

        if healthCheck(port: proxyPort) {
            if RunRegistry.active().isEmpty {
                Log.say("forge", "recycling stale proxy on :\(proxyPort)")
                stop()
            } else {
                Log.say("forge", "already up on :\(proxyPort)")
                return
            }
        }

        try ensureForge()

        let logPath = Paths.siftHome.appending(path: "forge-proxy.log")
        let pidPath = Paths.siftHome.appending(path: "forge-proxy.pid")
        Log.say("forge", "starting proxy on :\(proxyPort) → llama :\(llamaPort)")

        let logHandle: FileHandle
        do {
            logHandle = try RotatingLog.openForAppend(at: logPath)
        } catch {
            throw SiftError("can't write to \(logPath.path)")
        }

        let uvPath = try resolveUv()
        let proc = Process()
        proc.executableURL = URL(filePath: uvPath)
        proc.arguments = [
            "run",
            "--with", packageSpec,
            "--no-project",
            "--python", pythonVersion,
            "python", "-m", "forge.proxy",
            "--backend-url", "http://127.0.0.1:\(llamaPort)",
            "--port", String(proxyPort),
        ]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        // Same lifetime story as llama-server: the daemon (already
        // setsid'd) is the parent, so the forge proxy outlives the CLI
        // naturally.
        try proc.run()
        try? Data(String(proc.processIdentifier).utf8).write(to: pidPath)

        // First-run env build is slower than llama-server boot — uv may
        // download the wheel before forge even starts the HTTP server.
        // 120 s covers a cold network resolve on a typical line.
        for _ in 0..<120 {
            Thread.sleep(forTimeInterval: 1.0)
            if healthCheck(port: proxyPort) {
                Log.say("forge", "ready")
                return
            }
        }
        proc.terminate()
        for _ in 0..<10 {
            usleep(200_000)
            if !proc.isRunning { break }
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidPath)
        throw SiftError(
            "forge proxy didn't become ready in 120s",
            suggestion: "check \(logPath.path)"
        )
    }

    /// Kill the proxy (if a pidfile exists). Idempotent.
    public static func stop() {
        let pidPath = Paths.siftHome.appending(path: "forge-proxy.pid")
        defer { try? FileManager.default.removeItem(at: pidPath) }
        guard let data = try? Data(contentsOf: pidPath),
              let raw = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(raw),
              kill(pid, 0) == 0
        else { return }
        Log.say("forge", "stopping proxy (pid \(pid))")
        kill(pid, SIGTERM)
        for _ in 0..<10 {
            usleep(200_000)
            if kill(pid, 0) != 0 { return }
        }
        kill(pid, SIGKILL)
    }

    /// Stop only when no other auto sessions are still running. Mirrors
    /// `LlamaServer.stopLocalIfIdle()` so the proxy doesn't get torn
    /// down underneath a concurrent run.
    public static func stopIfIdle() {
        if !RunRegistry.active().isEmpty { return }
        stop()
    }

    // MARK: - Install / dependency check

    /// Verify `uv` is on PATH and warm the forge-guardrails cache.
    /// Called from `sift init` (eagerly, so the user pays the download
    /// cost upfront) and from `start()` as a safety net for installs
    /// that pre-date this feature.
    public static func ensureForge() throws {
        let uvPath = try resolveUv()
        // `uv run --with forge-guardrails python -c "import forge"`
        // resolves and caches the wheel without leaving anything else
        // running. Subsequent `uv run` calls reuse the same cached env.
        Log.say("forge", "ensuring forge-guardrails is cached (first run downloads)")
        try Subprocess.check([
            uvPath, "run",
            "--with", packageSpec,
            "--no-project",
            "--python", pythonVersion,
            "python", "-c", "import forge",
        ])
    }

    // MARK: - Internal

    private static func resolveUv() throws -> String {
        guard let path = Subprocess.which("uv") else {
            throw SiftError(
                "uv not found on PATH",
                suggestion: "install with: brew install uv"
            )
        }
        return path
    }
}
