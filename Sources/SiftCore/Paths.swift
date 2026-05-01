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
