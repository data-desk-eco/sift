import Foundation
import Testing
@testable import SiftCore

@Suite struct MarathonTests {

    @Test func continuationPromptAnchorsToReportAndFindings() {
        let p = PiRunner.continuationPrompt(
            original: "investigate Acme Corp's offshore filings",
            legNumber: 3
        )
        // Must restate the original goal so a fresh-context pi knows
        // what it's continuing.
        #expect(p.contains("investigate Acme Corp's offshore filings"))
        // Must point at the durable state in the cwd.
        #expect(p.contains("report.md"))
        #expect(p.contains("findings.db"))
        // Must say which leg this is — useful in the auto.log and as a
        // signal to the agent that this isn't a fresh investigation.
        #expect(p.contains("leg 3"))
    }

    @Test func runStateRoundTripsMarathonFields() throws {
        try withTempHome { home in
            let root = home.appending(path: "research")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try withEnv(["ALEPH_SESSION_DIR": root.path]) {
                let dir = root.appending(path: "ml-run")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var state = RunState(
                    session: "ml-run", sessionDir: dir.path,
                    logPath: dir.appending(path: "auto.log").path,
                    prompt: "x", pid: getpid(),
                    startedAt: 1_700_000_000
                )
                state.marathonEndTs = 1_700_010_000
                state.legNumber = 2
                try RunRegistry.write(state)

                let read = RunRegistry.read("ml-run")
                #expect(read?.marathonEndTs == 1_700_010_000)
                #expect(read?.legNumber == 2)
            }
        }
    }

    @Test func reportLooksMissingDetectsAbsentAndStubFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // No report at all: definitely missing.
        #expect(PiRunner.reportLooksMissing(sessionDir: dir))

        let report = dir.appending(path: "report.md")
        // Empty file (touch): also treated as missing.
        try Data().write(to: report)
        #expect(PiRunner.reportLooksMissing(sessionDir: dir))

        // Trivial stub under the threshold: still missing.
        try Data("# Report\n".utf8).write(to: report)
        #expect(PiRunner.reportLooksMissing(sessionDir: dir))

        // Substantial content: not missing — wrap-up should skip it.
        let real = String(repeating: "x", count: PiRunner.reportMinBytes + 10)
        try Data(real.utf8).write(to: report)
        #expect(!PiRunner.reportLooksMissing(sessionDir: dir))
    }

    @Test func wrapUpPromptMentionsReportAndStyle() {
        let p = PiRunner.wrapUpPrompt
        // Must name the file the agent has to produce.
        #expect(p.contains("report.md"))
        // Must remind the agent to use what it already has — opening
        // new searches at wrap-up time would burn the wrap-up budget
        // on tool calls instead of writing.
        #expect(p.lowercased().contains("don't open new") || p.lowercased().contains("do not open new"))
        // Must point at the style guide so the wrap-up output matches
        // a normal report (citations, neutral tone).
        #expect(p.contains("citations") || p.contains("citation"))
    }

    @Test func nonMarathonRunStateLeavesLegFieldsNil() throws {
        try withTempHome { home in
            let root = home.appending(path: "research")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try withEnv(["ALEPH_SESSION_DIR": root.path]) {
                let dir = root.appending(path: "solo")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let state = RunState(
                    session: "solo", sessionDir: dir.path,
                    logPath: dir.appending(path: "auto.log").path,
                    prompt: "x", pid: getpid(),
                    startedAt: 1_700_000_000
                )
                try RunRegistry.write(state)
                let read = RunRegistry.read("solo")
                #expect(read?.marathonEndTs == nil)
                #expect(read?.legNumber == nil)
            }
        }
    }
}
