import Foundation
import os

public enum Log {
    private static let osLog = Logger(subsystem: "eco.datadesk.sift", category: "default")

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }
    public static func debug(_ message: String) { write("DEBUG", message) }

    /// Write a `[scope]   message` line to stderr, with `scope` padded
    /// to 9 columns to match `EventStream`'s log shape. Used by every
    /// `sift` subcommand for visible CLI progress.
    public static func say(_ scope: String, _ message: String) {
        let tag = "[\(scope)]"
        let padded = tag.count >= 9
            ? tag
            : tag + String(repeating: " ", count: 9 - tag.count)
        let line = "\(padded) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static var logPath: URL {
        try? Paths.ensure(Paths.logDir)
        return Paths.logDir.appending(path: "sift.log")
    }

    private static func write(_ level: String, _ message: String) {
        switch level {
        case "ERROR": osLog.error("\(message)")
        case "DEBUG": osLog.debug("\(message)")
        default: osLog.info("\(message)")
        }

        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts)  \(level.padding(toLength: 5, withPad: " ", startingAt: 0))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            let handle = try RotatingLog.openForAppend(at: logPath)
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            osLog.error("log file write failed: \(error.localizedDescription)")
        }
    }
}
