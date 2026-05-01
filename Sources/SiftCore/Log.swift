import Foundation
import os

public enum Log {
    private static let osLog = Logger(subsystem: "eco.datadesk.sift", category: "default")

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }
    public static func debug(_ message: String) { write("DEBUG", message) }

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
        let path = logPath
        if let handle = try? FileHandle(forWritingTo: path) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                osLog.error("log file write failed: \(error.localizedDescription)")
            }
        } else {
            FileManager.default.createFile(atPath: path.path, contents: data)
        }
    }
}
