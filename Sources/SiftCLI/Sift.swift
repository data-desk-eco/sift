import ArgumentParser
import Foundation
import SiftCore

@main
struct SiftRoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sift",
        abstract: "Investigate subjects in Aleph or OpenAleph from your Mac.",
        discussion: """
            All state lives under ~/.sift (vault, models, pi config, run state).
            Secrets live in the macOS Keychain. Vault unlock is gated by Touch ID.
            """,
        version: Sift.version,
        subcommands: [
            InitCommand.self,
            AutoCommand.self,
            StatusCommand.self,
            LogsCommand.self,
            AttachCommand.self,
            StopCommand.self,
            TimeCommand.self,
            VaultCommand.self,
            ProjectCommand.self,
            BackendCommand.self,
            SearchCommand.self,
            ReadCommand.self,
            SourcesCommand.self,
            HubsCommand.self,
            SimilarCommand.self,
            ExpandCommand.self,
            BrowseCommand.self,
            TreeCommand.self,
            NeighborsCommand.self,
            RecallCommand.self,
            SQLCommand.self,
            CacheCommand.self,
            ExportCommand.self,
        ]
    )

    /// Custom run() dispatches sub-commands for us; this stub keeps
    /// ArgumentParser happy when invoked with `--help`/`--version`.
    func run() async throws {
        print(SiftRoot.helpMessage())
    }
}

/// Surface SiftError in the same `[ERROR]\n  → suggestion` shape the
/// Python CLI used. Used by every subcommand's run().
@discardableResult
func reportSiftError(_ error: Error) -> Int32 {
    if let s = error as? SiftError {
        FileHandle.standardError.write(Data("[ERROR]    \(s.message)\n".utf8))
        if !s.suggestion.isEmpty {
            FileHandle.standardError.write(Data("  → \(s.suggestion)\n".utf8))
        }
        return 1
    }
    FileHandle.standardError.write(Data("[ERROR]    \(error.localizedDescription)\n".utf8))
    return 1
}
