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

// MARK: - Research tools

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

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let input = SearchInput(
                query: query.joined(separator: " "),
                type: type ?? "any",
                limit: limit ?? 10,
                offset: offset ?? 0,
                collection: collection,
                sortByDate: sort == "date",
                noCache: noCache,
                emitter: emitter, recipient: recipient, mentions: mentions,
                dateFrom: dateFrom, dateTo: dateTo
            )
            emit(try await runSearch(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct ReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read", abstract: "Pull the full content of an entity by alias."
    )
    @Argument var alias: String
    @Flag(name: [.short, .customLong("full")]) var full: Bool = false
    @Flag(name: [.short, .customLong("raw")]) var raw: Bool = false

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let input = ReadInput(alias: alias, full: full, raw: raw)
            emit(try await runRead(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct SourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources", abstract: "List Aleph collections visible to your API key."
    )
    @Argument var grep: [String] = []
    @Option(name: [.short, .customLong("limit")]) var limit: Int?

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let g = grep.joined(separator: " ")
            let input = SourcesInput(grep: g.isEmpty ? nil : g, limit: limit ?? 50)
            emit(try await runSources(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
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

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let input = HubsInput(
                query: query.joined(separator: " "),
                collection: collection, schema: schema ?? "Email",
                limit: limit ?? 10
            )
            emit(try await runHubs(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct SimilarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "similar",
        abstract: "Aleph-extracted name-variant candidates for a party entity."
    )
    @Argument var alias: String
    @Option(name: [.short, .customLong("limit")]) var limit: Int?

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let input = SimilarInput(alias: alias, limit: limit ?? 10)
            emit(try await runSimilar(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct ExpandCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expand", abstract: "Show entities linked via FtM property refs."
    )
    @Argument var alias: String
    @Option(name: .customLong("property")) var property: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?
    @Flag(name: .customLong("no-cache")) var noCache: Bool = false

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let input = ExpandInput(
                alias: alias, property: property,
                limit: limit ?? 20, noCache: noCache
            )
            emit(try await runExpand(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct BrowseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browse", abstract: "Filesystem-style: parent folder and siblings."
    )
    @Argument var alias: String
    @Option(name: [.short, .customLong("limit")]) var limit: Int?

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let input = BrowseInput(alias: alias, limit: limit ?? 30)
            emit(try await runBrowse(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct TreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree", abstract: "ASCII subtree of a folder or collection roots."
    )
    @Argument var alias: String?
    @Option var collection: String?
    @Option var depth: Int?
    @Option(name: .customLong("max-siblings")) var maxSiblings: Int?

    func run() async throws {
        do {
            let store = try openSessionStore()
            let client = try Sift.makeAlephClient()
            let input = TreeInput(
                alias: alias, collection: collection,
                depth: depth ?? 3, maxSiblings: maxSiblings ?? 20
            )
            emit(try await runTree(client: client, store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct NeighborsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "neighbors", abstract: "Show every cached edge touching an entity."
    )
    @Argument var alias: String
    @Option var direction: String?
    @Option(name: .customLong("property")) var property: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?

    func run() async throws {
        do {
            let store = try openSessionStore()
            let input = NeighborsInput(
                alias: alias, direction: direction ?? "both",
                property: property, limit: limit ?? 50
            )
            emit(try runNeighbors(store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct RecallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recall", abstract: "Summarise what's in the local cache."
    )
    @Option var collection: String?
    @Option var schema: String?
    @Option(name: [.short, .customLong("limit")]) var limit: Int?

    func run() async throws {
        do {
            let store = try openSessionStore()
            let input = RecallInput(
                collection: collection, schema: schema, limit: limit ?? 15
            )
            emit(try runRecall(store: store, input: input))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct SQLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sql", abstract: "Read-only SQL against the cache DB."
    )
    @Argument var query: String

    func run() async throws {
        do {
            let store = try openSessionStore()
            emit(try runSQL(store: store, input: SQLInput(query: query)))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
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
    func run() async throws {
        do {
            emit(try runCacheStats(store: try openSessionStore()))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct CacheClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear")
    @Option(name: .customLong("older-than-days")) var olderThanDays: Int?

    func run() async throws {
        do {
            let store = try openSessionStore()
            emit(try runCacheClear(
                store: store,
                input: CacheClearInput(olderThanDays: olderThanDays)
            ))
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

// (Export lives in Commands/Export.swift)
