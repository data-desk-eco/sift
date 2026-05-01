import Foundation

public enum Paths {
    public static var siftHome: URL {
        if let override = ProcessInfo.processInfo.environment["SIFT_HOME"] {
            return URL(filePath: (override as NSString).expandingTildeInPath)
        }
        return URL(filePath: NSHomeDirectory()).appending(path: ".sift")
    }

    public static var runDir: URL { siftHome.appending(path: "run") }
    public static var logDir: URL { siftHome.appending(path: "log") }
    public static var modelsDir: URL { siftHome.appending(path: "models") }
    public static var piConfigDir: URL { siftHome.appending(path: "pi") }
    public static var projectFile: URL { siftHome.appending(path: "project.md") }
    public static var initMarker: URL { siftHome.appending(path: ".initialized") }
    public static var systemPromptFile: URL { siftHome.appending(path: "system-prompt.md") }

    /// Where the installer drops sift-owned tooling so we don't pollute
    /// npm globals and so uninstalling sift cleans up after itself.
    /// pi lives under here as a local npm install.
    public static var supportDir: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/Sift")
    }

    public static var bundledPiBin: URL {
        supportDir.appending(path: "pi/node_modules/.bin/pi")
    }

    /// Resolve an executable, preferring sift-bundled tooling over the
    /// user's `$PATH`. Currently special-cases `pi` (installed by the
    /// sift installer into our support dir); everything else goes
    /// straight to PATH.
    public static func findExecutable(_ name: String) -> String? {
        if name == "pi" {
            let bundled = bundledPiBin.path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        // Fall back to PATH.
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

    public static func ensureSiftHome() throws {
        try FileManager.default.createDirectory(
            at: siftHome, withIntermediateDirectories: true
        )
    }

    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
    }
}
