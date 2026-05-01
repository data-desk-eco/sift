import ArgumentParser
import Foundation
import SiftCore

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Show or edit the project description prepended to the agent's system prompt.",
        subcommands: [
            ProjectShow.self, ProjectSet.self, ProjectEdit.self, ProjectClear.self,
        ],
        defaultSubcommand: ProjectShow.self
    )
}

struct ProjectShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show")
    func run() async throws {
        do {
            try printProject()
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct ProjectSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set")
    @Argument var description: String?

    func run() async throws {
        do {
            let body = (description ?? promptUser("Briefly describe the project (data source and subject of investigation):"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                throw SiftError("description required")
            }
            try Paths.ensureSiftHome()
            try (body + "\n").write(to: Paths.projectFile, atomically: true, encoding: .utf8)
            print("[project]  saved to \(Paths.projectFile.path)")
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct ProjectEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit")
    func run() async throws {
        do {
            try Paths.ensureSiftHome()
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
            let proc = Process()
            proc.executableURL = URL(filePath: "/usr/bin/env")
            proc.arguments = [editor, Paths.projectFile.path]
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw ExitCode(reportSiftError(error))
        }
    }
}

struct ProjectClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear")
    func run() async throws {
        if FileManager.default.fileExists(atPath: Paths.projectFile.path) {
            try? FileManager.default.removeItem(at: Paths.projectFile)
        }
        print("[project]  cleared")
    }
}

func printProject() throws {
    guard FileManager.default.fileExists(atPath: Paths.projectFile.path) else {
        throw SiftError(
            "no project context set",
            suggestion: "run 'sift init' or 'sift project set'"
        )
    }
    let body = (try? String(contentsOf: Paths.projectFile, encoding: .utf8)) ?? ""
    if !body.isEmpty {
        print(body, terminator: "")
        if !body.hasSuffix("\n") { print() }
    }
}

func promptUser(_ prompt: String, secret: Bool = false) -> String {
    FileHandle.standardError.write(Data("\(prompt) ".utf8))
    if secret {
        if let raw = String(validatingCString: getpass("")) { return raw }
        return ""
    }
    return readLine(strippingNewline: true) ?? ""
}
