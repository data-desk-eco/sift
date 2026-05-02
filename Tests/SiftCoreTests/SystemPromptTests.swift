import Foundation
import Testing
@testable import SiftCore

@Suite struct SystemPromptStripFrontmatterTests {

    @Test func stripsLeadingFrontmatterBlock() {
        let input = """
            ---
            name: sift
            description: do things
            ---

            # Body
            here it is
            """
        let out = SystemPrompt.stripFrontmatter(input)
        #expect(out == "# Body\nhere it is")
    }

    @Test func leavesContentWithoutFrontmatter() {
        let input = "# Title\n\nNo frontmatter here."
        #expect(SystemPrompt.stripFrontmatter(input) == input)
    }

    @Test func leavesUnclosedFrontmatterAlone() {
        // Missing closing `---` — don't accidentally swallow the body.
        let input = "---\nstart but no end\nbody body body"
        #expect(SystemPrompt.stripFrontmatter(input) == input)
    }

    @Test func handlesMultilineFrontmatterValues() {
        let input = """
            ---
            description: |
              line one
              line two
            other: value
            ---
            BODY
            """
        #expect(SystemPrompt.stripFrontmatter(input) == "BODY")
    }
}

/// `SystemPrompt.build` is harder — it writes to disk, reads bundled
/// resources. Here we exercise it with a bespoke `resourceFinder` that
/// returns local fixtures so we don't depend on `Bundle.module`.
@Suite(.serialized) struct SystemPromptBuildTests {

    private func withTempHome(_ block: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prior = ProcessInfo.processInfo.environment["SIFT_HOME"]
        setenv("SIFT_HOME", dir.path, 1)
        defer {
            if let prior { setenv("SIFT_HOME", prior, 1) } else { unsetenv("SIFT_HOME") }
            try? FileManager.default.removeItem(at: dir)
        }
        try block(dir)
    }

    @Test func combinesAgentsAndSkillFiles() throws {
        try withTempHome { _ in
            let tmp = FileManager.default.temporaryDirectory
                .appending(path: "fixtures-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let agentsURL = tmp.appending(path: "AGENTS.md")
            let skillURL = tmp.appending(path: "SKILL.md")
            try "AGENT BODY".write(to: agentsURL, atomically: true, encoding: .utf8)
            try "---\nname: sift\n---\nSKILL BODY".write(to: skillURL, atomically: true, encoding: .utf8)

            SystemPrompt.resourceFinder = {
                .init(agentsMD: agentsURL, skillMD: skillURL)
            }
            let outURL = try SystemPrompt.build()
            let body = try String(contentsOf: outURL, encoding: .utf8)
            #expect(body.contains("AGENT BODY"))
            #expect(body.contains("SKILL BODY"))
            #expect(!body.contains("name: sift"))  // frontmatter stripped
        }
    }

    @Test func appendsDeadlineNoteWhenSupplied() throws {
        try withTempHome { _ in
            let tmp = FileManager.default.temporaryDirectory
                .appending(path: "fixtures-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let agentsURL = tmp.appending(path: "AGENTS.md")
            let skillURL = tmp.appending(path: "SKILL.md")
            try "A".write(to: agentsURL, atomically: true, encoding: .utf8)
            try "S".write(to: skillURL, atomically: true, encoding: .utf8)

            SystemPrompt.resourceFinder = {
                .init(agentsMD: agentsURL, skillMD: skillURL)
            }
            let outURL = try SystemPrompt.build(
                deadlineNote: .init(totalMinutes: 30, endLocalTime: "15:30")
            )
            let body = try String(contentsOf: outURL, encoding: .utf8)
            #expect(body.contains("## Deadline"))
            #expect(body.contains("30 minute"))
            #expect(body.contains("15:30"))
        }
    }

    @Test func throwsWhenResourcesAreMissing() throws {
        try withTempHome { _ in
            SystemPrompt.resourceFinder = { .init(agentsMD: nil, skillMD: nil) }
            #expect(throws: SiftError.self) {
                _ = try SystemPrompt.build()
            }
        }
    }
}
