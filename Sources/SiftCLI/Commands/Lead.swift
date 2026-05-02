import ArgumentParser
import Foundation
import SiftCore

struct LeadCommand: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "lead",
        abstract: "Show or switch the active lead.",
        discussion: """
            Sets the lead that `sift auto`, `logs`, `attach`, `stop` and
            `time` default to. Without an argument, prints the current
            lead. Pass --clear to revert to "most recent" semantics.
            """
    )

    @Argument(help: "session name to switch to")
    var name: String?

    @Flag(name: .customLong("clear"),
          help: "forget the active lead and fall back to most-recent")
    var clear: Bool = false

    func execute() async throws {
        if clear {
            ActiveLead.clear()
            print("active lead cleared (now defaults to most recent)")
            return
        }

        guard let name else {
            if let current = ActiveLead.get() {
                print(current)
                if RunRegistry.read(current) == nil {
                    Log.say("lead", "warning: \(current) is set but no run-state file exists")
                }
            } else {
                print("(no active lead — defaulting to most recent)")
            }
            return
        }

        // Validate the target before switching, so a typo doesn't
        // leave the user pointing at nothing.
        guard RunRegistry.read(name) != nil else {
            throw SiftError(
                "no such session: \(name)",
                suggestion: "run `sift status -a` to see every recorded lead"
            )
        }
        ActiveLead.set(name)
        print("active lead → \(name)")
    }
}
