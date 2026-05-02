import ArgumentParser
import Foundation
import SiftCore

struct LeadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lead",
        abstract: "Show or switch the active lead.",
        discussion: """
            The active lead is the default target for follow-up commands —
            `sift auto`, `sift logs`, `sift stop`, `sift time`, and the
            `*` marker in `sift status`. Without a subcommand, prints
            the current lead.
            """,
        subcommands: [LeadShow.self, LeadUse.self, LeadClear.self],
        defaultSubcommand: LeadShow.self
    )
}

struct LeadShow: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the active lead."
    )

    func execute() async throws {
        guard let current = ActiveLead.get() else {
            print("(no active lead — defaulting to most recent)")
            return
        }
        print(current)
        if RunRegistry.read(current) == nil {
            Log.say("lead", "warning: \(current) is set but no run-state file exists")
        }
    }
}

struct LeadUse: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Pin a lead as the active one."
    )

    @Argument(help: "lead name to switch to")
    var name: String

    func execute() async throws {
        // Validate the target before switching, so a typo doesn't leave
        // the user pointing at nothing.
        guard RunRegistry.read(name) != nil else {
            throw SiftError(
                "no such lead: \(name)",
                suggestion: "run `sift status -a` to see every recorded lead"
            )
        }
        ActiveLead.set(name)
        print("active lead → \(name)")
    }
}

struct LeadClear: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Forget the active lead and fall back to most-recent."
    )

    func execute() async throws {
        ActiveLead.clear()
        print("active lead cleared (now defaults to most recent)")
    }
}
