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

    /// Legacy install location for sift-owned tooling. Kept so that
    /// dev installs via `make install` still work (they drop pi here);
    /// brew-cask installs put pi inside Sift.app instead.
    public static var supportDir: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/Sift")
    }

    /// The Sift.app root, if the running process can find it by walking
    /// up from its own executable. Returns nil for dev / `swift run`
    /// builds where there is no enclosing .app. Works for both the
    /// menu bar app (whose Bundle.main IS the .app) and the CLI (whose
    /// Bundle.main is `Sift.app/Contents/Resources/bin`).
    public static func bundledAppRoot() -> URL? {
        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            if url.pathExtension == "app" { return url }
            let parent = url.deletingLastPathComponent()
            if parent == url { return nil }
            url = parent
        }
        return nil
    }

    /// In-bundle pi install (preferred for brew-cask installs) or the
    /// legacy support-dir location (for dev `make install`).
    public static var bundledPiBin: URL {
        if let app = bundledAppRoot() {
            return app.appending(path: "Contents/Resources/pi/node_modules/.bin/pi")
        }
        return supportDir.appending(path: "pi/node_modules/.bin/pi")
    }

    /// In-bundle CLI (when running inside Sift.app) — used by the menu
    /// bar app, which lives in the same bundle and can't trust $PATH
    /// since GUI apps don't inherit the user's shell environment.
    public static var bundledCLIBin: URL? {
        bundledAppRoot()?.appending(path: "Contents/Resources/bin/sift")
    }

    /// Resolve an executable, preferring sift-bundled tooling over the
    /// user's `$PATH`. Special-cases `pi` (bundled inside Sift.app, or
    /// in `~/Library/Application Support/Sift/pi/` for dev installs)
    /// and `sift` (bundled inside Sift.app).
    public static func findExecutable(_ name: String) -> String? {
        if name == "pi" {
            let bundled = bundledPiBin.path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        if name == "sift", let bundled = bundledCLIBin?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return Subprocess.which(name)
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
