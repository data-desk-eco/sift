import ArgumentParser
import Foundation
import SiftCore

// Stubs for subcommands implemented in tasks #6–#9. They keep the help
// surface complete so `sift --help` shows everything; running them
// prints a short note pointing at the in-progress task.

private func notImplemented(_ name: String) throws -> Never {
    throw ExitCode(reportSiftError(SiftError(
        "`\(name)` not yet wired up in the Swift rewrite",
        suggestion: "tracked under TaskList — coming next"
    )))
}

// MARK: - auto / status / logs / attach / stop (task #8)

struct AutoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Run the agent. Detaches; check progress with `sift status` or the menu bar.",
        discussion: "With PROMPT, launches a headless one-shot daemon and returns to the shell. "
            + "Without PROMPT, drops into an interactive REPL (foreground)."
    )
    @Argument(parsing: .captureForPassthrough) var prompt: [String] = []
    @Flag(name: .customLong("debug")) var debug: Bool = false
    @Option(name: [.short, .customLong("time-limit")],
            help: "soft deadline (e.g. 30m, 1h30m, 90s)")
    var timeLimit: String?
    @Flag(name: [.short, .customLong("new")],
          help: "start a fresh session instead of continuing the most recent one")
    var new: Bool = false

    func run() async throws { try notImplemented("auto") }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show running auto-session(s)."
    )
    func run() async throws { try notImplemented("status") }
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Tail the most recent auto-session log."
    )
    @Flag(name: [.short, .customLong("follow")]) var follow: Bool = false
    func run() async throws { try notImplemented("logs") }
}

struct AttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach", abstract: "Re-attach to a running auto-session in the terminal."
    )
    func run() async throws { try notImplemented("attach") }
}

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop the running auto-session."
    )
    func run() async throws { try notImplemented("stop") }
}

// MARK: - Research tools (task #6)

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "Search the collection for hits."
    )
    @Argument var query: [String] = []
    @Option(name: .customLong("type")) var type: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    @Option(name: [.short, .customLong("offset")]) var offset: Int?
    @Option var collection: String?
    @Option var sort: String?
    @Flag(name: .customLong("no-cache")) var noCache: Bool = false
    @Option var emitter: String?
    @Option var recipient: String?
    @Option var mentions: String?
    @Option(name: .customLong("date-from")) var dateFrom: String?
    @Option(name: .customLong("date-to")) var dateTo: String?

    func run() async throws { try notImplemented("search") }
}

struct ReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read", abstract: "Pull the full content of an entity by alias."
    )
    @Argument var alias: String
    @Flag(name: [.short, .customLong("full")]) var full: Bool = false
    @Flag(name: [.short, .customLong("raw")]) var raw: Bool = false
    func run() async throws { try notImplemented("read") }
}

struct SourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources", abstract: "List Aleph collections visible to your API key."
    )
    @Argument var grep: [String] = []
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    func run() async throws { try notImplemented("sources") }
}

struct HubsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hubs",
        abstract: "Top emitters / recipients / mentions for entities matching a query."
    )
    @Argument var query: [String] = []
    @Option var collection: String?
    @Option var schema: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    func run() async throws { try notImplemented("hubs") }
}

struct SimilarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "similar",
        abstract: "Aleph-extracted name-variant candidates for a party entity."
    )
    @Argument var alias: String
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    func run() async throws { try notImplemented("similar") }
}

struct ExpandCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expand", abstract: "Show entities linked via FtM property refs."
    )
    @Argument var alias: String
    @Option(name: .customLong("property")) var property: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    @Flag(name: .customLong("no-cache")) var noCache: Bool = false
    func run() async throws { try notImplemented("expand") }
}

struct BrowseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browse", abstract: "Filesystem-style: parent folder and siblings."
    )
    @Argument var alias: String
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    func run() async throws { try notImplemented("browse") }
}

struct TreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree", abstract: "ASCII subtree of a folder or collection roots."
    )
    @Argument var alias: String?
    @Option var collection: String?
    @Option var depth: Int?
    @Option(name: .customLong("max-siblings")) var maxSiblings: Int?
    func run() async throws { try notImplemented("tree") }
}

struct NeighborsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "neighbors", abstract: "Show every cached edge touching an entity."
    )
    @Argument var alias: String
    @Option var direction: String?
    @Option(name: .customLong("property")) var property: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    func run() async throws { try notImplemented("neighbors") }
}

struct RecallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recall", abstract: "Summarise what's in the local cache."
    )
    @Option var collection: String?
    @Option var schema: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    func run() async throws { try notImplemented("recall") }
}

struct SQLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sql", abstract: "Read-only SQL against the cache DB."
    )
    @Argument var query: String
    func run() async throws { try notImplemented("sql") }
}

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "Inspect or prune the local response cache.",
        subcommands: [CacheStats.self, CacheClear.self],
        defaultSubcommand: CacheStats.self
    )
}

struct CacheStats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats")
    func run() async throws { try notImplemented("cache stats") }
}

struct CacheClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear")
    @Option(name: .customLong("older-than-days")) var olderThanDays: Int?
    func run() async throws { try notImplemented("cache clear") }
}

// MARK: - Export (task #9)

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render report.md → report.html with alias→Aleph entity links."
    )
    @Argument var src: String?
    @Option(name: [.short, .customLong("out")]) var out: String?
    @Option var server: String?
    @Flag(name: .customLong("no-open")) var noOpen: Bool = false
    @Flag var share: Bool = false
    func run() async throws { try notImplemented("export") }
}
