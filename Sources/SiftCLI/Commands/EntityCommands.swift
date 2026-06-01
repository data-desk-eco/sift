import ArgumentParser
import Foundation
import SiftCore

/// `sift entity …` — the agent's structured-findings surface. Findings
/// are FollowTheMoney entities stored under `f` aliases in the per-session
/// findings DB. Agent-facing (documented in SKILL.md).

struct EntityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entity",
        abstract: "Record structured findings as FollowTheMoney entities.",
        subcommands: [
            EntityCreate.self, EntityEdit.self, EntityDelete.self,
            EntityList.self, EntityShow.self, EntitySchemas.self,
        ],
        defaultSubcommand: EntityList.self
    )
}

struct EntityCreate: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a finding from a schema and properties."
    )
    @Argument(help: "FtM schema, e.g. Person, Company, Payment.") var schema: String?
    @Option(name: [.short, .customLong("prop")],
            help: "Property as key=value (repeatable). Refs accept f/r aliases.") var prop: [String] = []
    @Option(name: [.short, .customLong("source")],
            help: "Aleph alias(es) this finding came from (repeatable / comma-separated).") var source: [String] = []
    @Option(help: "Full FtM entity or properties object as JSON.") var json: String?

    func execute() async throws {
        let aleph = try openSessionStore()
        let findings = try Session.openFindings()
        emit(try runEntityCreate(
            findings: findings, aleph: aleph,
            input: EntityCreateInput(schema: schema, json: json, props: prop, sources: source)
        ))
    }
}

struct EntityEdit: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a finding in place."
    )
    @Argument(help: "Findings alias, e.g. f3.") var alias: String
    @Option(name: [.short, .customLong("prop")], help: "Set property key=value (repeatable).") var prop: [String] = []
    @Option(name: .customLong("remove"), help: "Remove a property (repeatable).") var remove: [String] = []
    @Option(name: [.short, .customLong("source")], help: "Replace the source alias(es).") var source: [String] = []
    @Flag(name: .customLong("clear-sources"), help: "Drop all sources.") var clearSources = false
    @Option(help: "Change the schema.") var schema: String?
    @Option(help: "Replace all properties from JSON.") var json: String?

    func execute() async throws {
        let aleph = try openSessionStore()
        let findings = try Session.openFindings()
        let sources: [String]? = (!source.isEmpty || clearSources) ? source : nil
        emit(try runEntityEdit(
            findings: findings, aleph: aleph,
            input: EntityEditInput(
                alias: alias, schema: schema, json: json,
                props: prop, removeProps: remove, sources: sources
            )
        ))
    }
}

struct EntityDelete: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a finding."
    )
    @Argument(help: "Findings alias, e.g. f3.") var alias: String
    @Flag(help: "Delete even if other findings reference it.") var force = false

    func execute() async throws {
        let aleph = try openSessionStore()
        let findings = try Session.openFindings()
        emit(try runEntityDelete(
            findings: findings, aleph: aleph,
            input: EntityDeleteInput(alias: alias, force: force)
        ))
    }
}

struct EntityList: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recorded findings."
    )
    @Option(help: "Filter by schema.") var schema: String?
    @Flag(help: "Emit raw FtM JSON.") var json = false

    func execute() async throws {
        let aleph = try openSessionStore()
        let findings = try Session.openFindings()
        emit(try runEntityList(
            findings: findings, aleph: aleph,
            input: EntityListInput(schema: schema, json: json)
        ))
    }
}

struct EntityShow: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one finding in full."
    )
    @Argument(help: "Findings alias, e.g. f3.") var alias: String
    @Flag(help: "Emit raw FtM JSON.") var json = false

    func execute() async throws {
        let aleph = try openSessionStore()
        let findings = try Session.openFindings()
        emit(try runEntityShow(
            findings: findings, aleph: aleph,
            input: EntityShowInput(alias: alias, json: json)
        ))
    }
}

struct EntitySchemas: SiftSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "schemas",
        abstract: "List FtM schemas, or one schema's properties."
    )
    @Argument(help: "Schema name to detail.") var schema: String?

    func execute() async throws {
        emit(runEntitySchemas(name: schema))
    }
}
