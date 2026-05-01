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

            The Aleph and cache groups are the same surface the agent uses
            during `sift auto` runs — they're listed first because you'll
            reach for them most. The setup, auto and report groups below
            are for managing your own work.
            """,
        version: Sift.version,
        subcommands: [DaemonRunCommand.self],
        groupedSubcommands: [
            // Agent-facing tools (also fine to call interactively).
            CommandGroup(name: "Aleph", subcommands: [
                SearchCommand.self,
                ReadCommand.self,
                SourcesCommand.self,
                HubsCommand.self,
                SimilarCommand.self,
                ExpandCommand.self,
                BrowseCommand.self,
                TreeCommand.self,
                NeighborsCommand.self,
            ]),
            // The agent's self-knowledge tools: what's already in the
            // local cache, and how much time is left on the clock.
            CommandGroup(name: "Memory", subcommands: [
                RecallCommand.self,
                SQLCommand.self,
                CacheCommand.self,
                TimeCommand.self,
            ]),
            // Human-facing — manage your sift install + auto runs.
            CommandGroup(name: "Setup", subcommands: [
                InitCommand.self,
                VaultCommand.self,
                BackendCommand.self,
                ProjectCommand.self,
            ]),
            CommandGroup(name: "Auto", subcommands: [
                AutoCommand.self,
                LeadCommand.self,
                StatusCommand.self,
                LogsCommand.self,
                AttachCommand.self,
                StopCommand.self,
            ]),
            CommandGroup(name: "Report", subcommands: [
                ExportCommand.self,
            ]),
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
