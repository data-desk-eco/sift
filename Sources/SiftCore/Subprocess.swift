import Foundation

/// Run a child process and capture stdout + stderr. Reads both streams
/// concurrently so a child that writes >64 KiB to either pipe (the
/// macOS pipe buffer limit) doesn't deadlock waiting for us to drain.
public enum Subprocess {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let code: Int32
    }

    @discardableResult
    public static func run(
        _ args: [String],
        input: String? = nil,
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) throws -> Result {
        precondition(!args.isEmpty, "Subprocess.run requires at least an executable")

        let proc = Process()
        proc.executableURL = URL(filePath: args[0])
        proc.arguments = Array(args.dropFirst())
        if let env { proc.environment = env }
        if let cwd { proc.currentDirectoryURL = cwd }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try proc.run()

        if let input, let data = input.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        proc.waitUntilExit()
        group.wait()

        return Result(
            stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            code: proc.terminationStatus
        )
    }

    /// Throw a SiftError if the process exits non-zero.
    @discardableResult
    public static func check(
        _ args: [String],
        input: String? = nil,
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) throws -> Result {
        let result = try run(args, input: input, env: env, cwd: cwd)
        guard result.code == 0 else {
            let prog = (args.first as NSString?)?.lastPathComponent ?? "process"
            throw SiftError(
                "\(prog) failed (rc=\(result.code))",
                suggestion: result.stderr.isEmpty ? "" : result.stderr
            )
        }
        return result
    }

    /// Find an executable on `PATH`. Returns nil if not found. Pure
    /// Swift — no fork/exec — so it's safe to call from inside hot
    /// paths.
    public static func which(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
