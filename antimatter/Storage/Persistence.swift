import Foundation

/// Atomic text persistence for the scratchpad file, plus a one-generation
/// `.bak`: every overwrite first copies the current file aside, so even a
/// successful write of bad content (or a user's accidental deletion of the
/// primary) leaves the previous good save recoverable.
enum Persistence {
    /// The `<name>.<ext>.bak` sibling of `url`.
    static func backupURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(url.pathExtension + ".bak")
    }

    /// Reads `url`, falling back to its `.bak` when the primary file is
    /// missing or unreadable. Returns nil when neither can be read.
    static func read(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return try? String(contentsOf: backupURL(for: url), encoding: .utf8)
    }

    /// Atomically replaces `url` with `text`, preserving the current
    /// contents as the `.bak` first. Returns the write error, if any —
    /// a failed atomic write never touches the previous file.
    @discardableResult
    static func write(_ text: String, to url: URL) -> Error? {
        let backup = backupURL(for: url)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error
        }
    }
}
