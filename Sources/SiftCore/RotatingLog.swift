import Foundation

/// Open a log file for append, rotating it if the existing file is at
/// or past `maxBytes`. Rotation is one-deep: `foo.log` → `foo.log.1`,
/// overwriting any previous `.1`. That's enough to cap disk use without
/// the operational complexity of a multi-generation rotor — sift's
/// runs and the llama-server lifecycle don't produce logs valuable
/// past the last generation anyway.
public enum RotatingLog {
    /// Default cap. 10 MB is large enough to cover a normal multi-hour
    /// `sift auto` run with `--debug` on, small enough that a stuck
    /// agent can't fill the vault.
    public static let defaultMaxBytes: UInt64 = 10 * 1024 * 1024

    /// Returns a `FileHandle` positioned at end-of-file, ready to
    /// append. Creates the file if missing; rotates first if it's
    /// already at/past `maxBytes`.
    public static func openForAppend(
        at url: URL, maxBytes: UInt64 = defaultMaxBytes
    ) throws -> FileHandle {
        let fm = FileManager.default
        try Paths.ensure(url.deletingLastPathComponent())

        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64,
           size >= maxBytes {
            let rotated = url.appendingPathExtension("1")
            // Overwrite any previous .1 atomically: remove first so a
            // partial rename doesn't leave both files referring to the
            // same inode.
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
