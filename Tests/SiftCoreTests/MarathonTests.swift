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
