import Darwin
import Foundation

/// llama-server process lifecycle + the one-time install / model
/// download dance. Split from `Backend` (which keeps the on-disk
/// config types and the pi-config templating) so the process-management
/// surface is read in isolation from the config surface.
public enum LlamaServer {

    public static let defaultModelRepo = "unsloth/Qwen3.6-35B-A3B-GGUF"

    /// Bump when the llama-server startup args below change in any way
    /// that affects KV cache layout (ctx size, KV quant, flash-attn, the
    /// model arch via a defaultModelFile change). The version is part of
    /// the on-disk cache filename, so a bump silently invalidates every
    /// stale slot file the next time `sift auto` runs.
    public static let kvCacheVersion = 1

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

    /// Start whichever backend is configured. Hosted is config-only;
    /// local spawns `llama-server` detached, writes a pidfile, and
    /// polls until ready.
    public static func start() throws {
        let config = try Backend.requireConfig()
        switch config.kind {
        case .local:  try startLocal()
        case .hosted: return
        }
    }

    public static func startLocal() throws {
        let config = try Backend.requireConfig()
        guard config.kind == .local else { return }
        let port = config.port ?? Backend.defaultLocalPort
        if healthCheck(port: port) {
            // A long-lived llama-server accumulates KV cache state and
            // gets progressively slower — second-and-later auto sessions
            // were taking minutes to produce their first token. If no
            // other auto session is currently using it, kill the stale
            // server so this run gets a clean boot. Concurrent sessions
            // (rare) still share the warm one.
            if RunRegistry.active().isEmpty {
                Log.say("server", "recycling stale llama-server on :\(port)")
                stopLocal()
            } else {
                Log.say("server", "already up on :\(port)")
                return
            }
        }
        let modelPath = Paths.modelsDir.appending(path: config.modelFile ?? Backend.defaultModelFile)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw SiftError(
                "model not found at \(modelPath.path)",
                suggestion: "run 'sift init' to download it"
            )
        }
        try? Paths.ensure(Paths.kvCacheDir)
        let logPath = Paths.siftHome.appending(path: "llama-server.log")
        let pidPath = Paths.siftHome.appending(path: "llama-server.pid")
        Log.say("server", "starting llama-server on :\(port)")

        let logHandle: FileHandle
        do {
            logHandle = try RotatingLog.openForAppend(at: logPath)
        } catch {
            throw SiftError("can't write to \(logPath.path)")
        }

        let proc = Process()
        proc.executableURL = URL(filePath: try resolveExecutable("llama-server"))
        proc.arguments = [
            "--model", modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--jinja",
            "--no-webui",
            "--ctx-size", String(Backend.localContextWindow),
            "--reasoning-budget", "16384",
            "--flash-attn", "on",
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
            "--slot-save-path", Paths.kvCacheDir.path,
            "--alias", config.modelName,
        ]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        // Process inherits our session by default; that's fine here
        // because llama-server outlives the CLI naturally — the daemon
        // (or the user re-running `sift auto`) is the long-lived parent.
        try proc.run()
        try? Data(String(proc.processIdentifier).utf8).write(to: pidPath)

        for _ in 0..<120 {
            Thread.sleep(forTimeInterval: 1.0)
            if healthCheck(port: port) {
                Log.say("server", "ready")
                // Best-effort: warm the slot from disk so the first agent
                // request skips ~30 s of cold prompt-eval on the system
                // prompt. Missing or stale cache files just leave the
                // slot empty, which is the previous behaviour.
                restorePromptCache(port: port, modelFile: modelPath.lastPathComponent)
                return
            }
        }
        // Health check timed out — kill the unhealthy process so a
        // retry isn't blocked by a stale port. Without this, the
        // orphaned llama-server keeps holding :1234 (and ~14 GB) and
        // every subsequent `sift auto` greets the user with "address
        // already in use".
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
            "llama-server didn't become ready in 120s",
            suggestion: "check \(logPath.path)"
        )
    }

    /// Kill the local llama-server (if a pidfile exists) and remove the
    /// pidfile. Idempotent: silent no-op when the server isn't running.
    /// llama-server holds the model in unified memory (~14 GB for the
    /// default Qwen3.6 35B), which makes the rest of the Mac feel sluggish
    /// when no agent is using it.
    public static func stopLocal() {
        let pidPath = Paths.siftHome.appending(path: "llama-server.pid")
        defer { try? FileManager.default.removeItem(at: pidPath) }
        guard let data = try? Data(contentsOf: pidPath),
              let raw = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(raw),
              kill(pid, 0) == 0
        else { return }
        // Persist whatever KV state the slot ended this session with, so
        // the next start can restore it and skip cold prompt eval. Must
        // happen before SIGTERM — once the server is gone the state is
        // unrecoverable. Best-effort: a failed save just means the next
        // start pays the cold cost (the previous behaviour).
        if let config = Backend.readConfig(), config.kind == .local {
            let port = config.port ?? Backend.defaultLocalPort
            let modelFile = config.modelFile ?? Backend.defaultModelFile
            savePromptCache(port: port, modelFile: modelFile)
        }
        Log.say("server", "stopping llama-server (pid \(pid))")
        kill(pid, SIGTERM)
        // Give it ~2s to exit cleanly, then SIGKILL if still around.
        for _ in 0..<10 {
            usleep(200_000)
            if kill(pid, 0) != 0 { return }
        }
        kill(pid, SIGKILL)
    }

    /// Stop llama-server only when no other auto sessions are still
    /// running. Safe to call from `sift stop` and from the daemon's
    /// post-pi cleanup — the last one out turns off the lights.
    public static func stopLocalIfIdle() {
        if !RunRegistry.active().isEmpty { return }
        stopLocal()
    }

    // MARK: - Install + model download

    public static func ensureLlamacpp() throws {
        if Subprocess.which("llama-server") != nil { return }
        guard Subprocess.which("brew") != nil else {
            throw SiftError(
                "llama-server not installed and Homebrew not found",
                suggestion: "install Homebrew or install llama.cpp manually"
            )
        }
        Log.say("init", "installing llama.cpp via Homebrew")
        try Subprocess.check(["/usr/bin/env", "brew", "install", "llama.cpp"])
    }

    /// Download the recommended GGUF model into `~/.sift/models/`.
    /// Resolves the HF redirect first so curl's progress bar tracks the
    /// actual download, not the redirect document.
    public static func downloadModel() throws {
        try Paths.ensure(Paths.modelsDir)
        let modelPath = Paths.modelsDir.appending(path: Backend.defaultModelFile)
        if FileManager.default.fileExists(atPath: modelPath.path) {
            Log.say("init", "model already downloaded")
            return
        }
        Log.say("init", "downloading model (~12 GB)")

        let resolveURL = "https://huggingface.co/\(defaultModelRepo)/resolve/main/\(Backend.defaultModelFile)"
        let resolved = try resolveRedirect(resolveURL)
        let partial = modelPath.appendingPathExtension("partial")
        try Subprocess.check([
            "/usr/bin/env", "curl", "--fail", "--progress-bar",
            "--retry", "5", "--retry-all-errors",
            "-o", partial.path, resolved,
        ])
        try FileManager.default.moveItem(at: partial, to: modelPath)
    }

    // MARK: - KV prefix cache (slot persistence)

    /// Filename llama-server writes to / reads from inside
    /// `--slot-save-path`. Keyed on model + cache version so that
    /// swapping models or bumping the version invalidates stale slots
    /// without us having to clear the dir.
    public static func kvCacheFilename(modelFile: String) -> String {
        let stem = (modelFile as NSString).deletingPathExtension
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "sift-prefix-v\(kvCacheVersion)-\(stem).bin"
    }

    /// POST /slots/0?action=save. Best-effort: swallows errors so a
    /// failed save can't block the stop path.
    private static func savePromptCache(port: Int, modelFile: String) {
        let filename = kvCacheFilename(modelFile: modelFile)
        guard let url = URL(string: "http://127.0.0.1:\(port)/slots/0?action=save")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"filename\":\"\(filename)\"}".utf8)
        req.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                ok = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        if ok {
            Log.say("server", "saved KV prefix cache (\(filename))")
        }
    }

    /// POST /slots/0?action=restore. No-op when the file isn't on disk
    /// (first run, or after `kvCacheVersion` was bumped).
    private static func restorePromptCache(port: Int, modelFile: String) {
        let filename = kvCacheFilename(modelFile: modelFile)
        let kvFile = Paths.kvCacheDir.appending(path: filename)
        guard FileManager.default.fileExists(atPath: kvFile.path) else { return }
        guard let url = URL(string: "http://127.0.0.1:\(port)/slots/0?action=restore")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"filename\":\"\(filename)\"}".utf8)
        // Restoring a multi-GB slot can take a few seconds on a cold cache.
        req.timeoutInterval = 30
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                ok = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        if ok {
            Log.say("server", "restored KV prefix cache")
        } else {
            // Corrupt or incompatible (e.g. user swapped llama.cpp versions);
            // wipe so we don't keep retrying it every start.
            try? FileManager.default.removeItem(at: kvFile)
            Log.say("server", "discarded stale KV prefix cache")
        }
    }

    // MARK: - Internal

    private static func resolveExecutable(_ name: String) throws -> String {
        guard let path = Subprocess.which(name) else {
            throw SiftError(
                "missing dependency: \(name)",
                suggestion: "install: brew install llama.cpp"
            )
        }
        return path
    }

    /// Follow HEAD redirects manually so curl downloads the resolved URL
    /// (HF gives a CDN-signed URL via 302). Refuses any redirect that
    /// downgrades to plaintext or jumps to a non-http(s) scheme — a
    /// malicious or compromised redirect target shouldn't be able to
    /// trick us into downloading a 12 GB model over an unauthenticated
    /// channel.
    private static func resolveRedirect(_ url: String) throws -> String {
        var current = url
        for _ in 0..<5 {
            guard let u = URL(string: current),
                  let scheme = u.scheme?.lowercased(),
                  scheme == "https"
            else {
                throw SiftError(
                    "refusing non-https model URL: \(current)",
                    suggestion: "model downloads must come over HTTPS"
                )
            }
            var request = URLRequest(url: u)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 30
            let sem = DispatchSemaphore(value: 0)
            var resolved: String?
            var statusCode: Int = 0
            let session = URLSession(configuration: .ephemeral, delegate: NoFollowRedirect(), delegateQueue: nil)
            let task = session.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse {
                    statusCode = http.statusCode
                    if (300..<400).contains(http.statusCode),
                       let loc = http.value(forHTTPHeaderField: "Location") {
                        resolved = loc
                    }
                }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 30)
            if let next = resolved {
                current = next.hasPrefix("http") ? next : URL(string: next, relativeTo: u)?.absoluteString ?? next
            } else if (200..<300).contains(statusCode) {
                return current
            } else {
                break
            }
        }
        return current
    }

    private final class NoFollowRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
