import Foundation
import Testing
@testable import SiftCore

@Suite struct RotatingLogTests {

    /// Returns a fresh tmp directory; cleaned up by the test's defer.
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sift-rotlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createsFileIfMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "fresh.log")
        let handle = try RotatingLog.openForAppend(at: url)
        try handle.write(contentsOf: Data("hello\n".utf8))
        try handle.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello\n")
    }

    @Test func appendsToExistingFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "appendable.log")
        try Data("first\n".utf8).write(to: url)
        let handle = try RotatingLog.openForAppend(at: url)
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == "first\nsecond\n")
    }

    @Test func rotatesWhenOverThreshold() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "big.log")
        try Data(repeating: 0x41, count: 100).write(to: url)
        let handle = try RotatingLog.openForAppend(at: url, maxBytes: 50)
        try handle.write(contentsOf: Data("after-rotate\n".utf8))
        try handle.close()

        let rotated = url.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        #expect(try Data(contentsOf: rotated).count == 100)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after-rotate\n")
    }

    @Test func rotateOverwritesPriorRotation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "two-rounds.log")
        let rotated = url.appendingPathExtension("1")
        try Data("OLD-ROTATED".utf8).write(to: rotated)
        try Data(repeating: 0x42, count: 80).write(to: url)
        let handle = try RotatingLog.openForAppend(at: url, maxBytes: 50)
        try handle.close()
        // Prior `.1` overwritten with the rotated primary's bytes.
        #expect(try Data(contentsOf: rotated).count == 80)
    }

    @Test func doesNotRotateUnderThreshold() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "small.log")
        try Data("tiny\n".utf8).write(to: url)
        let handle = try RotatingLog.openForAppend(at: url, maxBytes: 1024 * 1024)
        try handle.write(contentsOf: Data("more\n".utf8))
        try handle.close()
        let rotated = url.appendingPathExtension("1")
        #expect(!FileManager.default.fileExists(atPath: rotated.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "tiny\nmore\n")
    }
}
