import Foundation
import Testing
@testable import SiftCore

@Suite struct SubprocessRunTests {

    @Test func capturesStdoutOfSimpleCommand() throws {
        let result = try Subprocess.run(["/bin/echo", "hello"])
        #expect(result.code == 0)
        #expect(result.stdout == "hello")
        #expect(result.stderr == "")
    }

    @Test func capturesStderrOfFailingCommand() throws {
        // /usr/bin/false exits 1 with no output. Use a shell to write
        // to stderr so we have something to assert on.
        let result = try Subprocess.run(["/bin/sh", "-c", "echo to-err >&2; exit 7"])
        #expect(result.code == 7)
        #expect(result.stdout == "")
        #expect(result.stderr == "to-err")
    }

    @Test func passesInputToStdin() throws {
        // `cat` echoes whatever it gets on stdin.
        let result = try Subprocess.run(["/bin/cat"], input: "ping\n")
        #expect(result.code == 0)
        #expect(result.stdout == "ping")
    }

    @Test func envOverridesAreVisibleInChild() throws {
        let result = try Subprocess.run(
            ["/bin/sh", "-c", "echo $SIFT_TEST_VAR"],
            env: ["SIFT_TEST_VAR": "marker", "PATH": "/bin:/usr/bin"]
        )
        #expect(result.stdout == "marker")
    }

    @Test func cwdAffectsRelativePaths() throws {
        let result = try Subprocess.run(["/bin/pwd"], cwd: URL(filePath: "/tmp"))
        #expect(result.stdout == "/tmp" || result.stdout == "/private/tmp")
    }
}

@Suite struct SubprocessCheckTests {

    @Test func checkReturnsResultOnZeroExit() throws {
        let result = try Subprocess.check(["/bin/echo", "ok"])
        #expect(result.stdout == "ok")
    }

    @Test func checkThrowsOnNonZeroExit() {
        #expect(throws: SiftError.self) {
            _ = try Subprocess.check(["/bin/sh", "-c", "exit 42"])
        }
    }

    @Test func checkErrorIncludesProgramName() {
        do {
            _ = try Subprocess.check(["/bin/sh", "-c", "exit 1"])
            Issue.record("expected throw")
        } catch let error as SiftError {
            #expect(error.message.contains("sh"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

@Suite struct SubprocessWhichTests {

    @Test func findsKnownBinary() {
        // /bin/echo is on every macOS install.
        let path = Subprocess.which("echo")
        #expect(path != nil)
        if let path {
            #expect(FileManager.default.isExecutableFile(atPath: path))
        }
    }

    @Test func returnsNilForNonexistentBinary() {
        #expect(Subprocess.which("definitely-not-a-real-binary-\(UUID().uuidString)") == nil)
    }
}
