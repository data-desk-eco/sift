import Foundation
import Testing
@testable import SiftCore

@Suite struct PiRunnerResolveSessionTests {

    /// Build a research-dir fixture with the given session sub-dirs,
    /// each timestamped at the supplied modification time.
    private func makeResearch(_ sessions: [(name: String, mtime: Date)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, mtime) in sessions {
            let sub = dir.appending(path: name)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: sub.path
            )
        }
        return dir
    }

    @Test func leadDirWinsWhenNotNew() throws {
        let dir = try makeResearch([("recent", Date())])
        defer { try? FileManager.default.removeItem(at: dir) }
        let lead = dir.appending(path: "pinned")
        let res = PiRunner.resolveSession(
            researchDir: dir, prompt: nil, newSession: false,
            leadDir: lead
        )
        #expect(res.sessionDir == lead)
        #expect(res.resuming)
        #expect(res.staleAge == nil)
    }

    @Test func leadDirIgnoredWhenNew() throws {
        let dir = try makeResearch([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let lead = dir.appending(path: "pinned")
        let res = PiRunner.resolveSession(
            researchDir: dir, prompt: "fresh", newSession: true,
            leadDir: lead, freshSlug: "fresh"
        )
        #expect(res.sessionDir.lastPathComponent == "fresh")
        #expect(!res.resuming)
    }

    @Test func resumesMostRecentWhenNoLead() throws {
        let now = Date()
        let dir = try makeResearch([
            ("old", now.addingTimeInterval(-3600)),
            ("recent", now),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = PiRunner.resolveSession(
            researchDir: dir, prompt: nil, newSession: false
        )
        #expect(res.sessionDir.lastPathComponent == "recent")
        #expect(res.resuming)
    }

    @Test func tagsStaleResumeWhenAgeOverThreshold() throws {
        let oldEnough = Date().addingTimeInterval(-Double(PiRunner.staleSessionHours + 1) * 3600)
        let dir = try makeResearch([("vintage", oldEnough)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = PiRunner.resolveSession(
            researchDir: dir, prompt: nil, newSession: false
        )
        #expect(res.sessionDir.lastPathComponent == "vintage")
        #expect(res.staleAge != nil)
    }

    @Test func skipsDefaultSubdirWhenPickingMostRecent() throws {
        // The "default" REPL bucket must not count as a resumable.
        let now = Date()
        let dir = try makeResearch([
            ("default", now),
            ("real-session", now.addingTimeInterval(-60)),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = PiRunner.resolveSession(
            researchDir: dir, prompt: nil, newSession: false
        )
        #expect(res.sessionDir.lastPathComponent == "real-session")
    }

    @Test func emptyResearchWithPromptCreatesSlug() throws {
        let dir = try makeResearch([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = PiRunner.resolveSession(
            researchDir: dir, prompt: "go", newSession: false,
            freshSlug: "freshly-named"
        )
        #expect(res.sessionDir.lastPathComponent == "freshly-named")
        #expect(!res.resuming)
    }

    @Test func emptyResearchWithoutPromptLandsOnDefault() throws {
        let dir = try makeResearch([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = PiRunner.resolveSession(
            researchDir: dir, prompt: nil, newSession: false
        )
        #expect(res.sessionDir.lastPathComponent == "default")
    }
}

@Suite struct PiRunnerHelperTests {

    @Test func formatAgeReportsHoursThenDays() {
        #expect(PiRunner.formatAge(1) == "1h")
        #expect(PiRunner.formatAge(47) == "47h")
        #expect(PiRunner.formatAge(48) == "2d")
        #expect(PiRunner.formatAge(72) == "3d")
    }

    @Test func mostRecentSessionReturnsNilOnMissingDir() {
        let bogus = FileManager.default.temporaryDirectory
            .appending(path: "no-such-dir-\(UUID().uuidString)")
        #expect(PiRunner.mostRecentSession(researchDir: bogus) == nil)
    }
}
