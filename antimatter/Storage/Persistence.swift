import Foundation

/// Where mutable app data lives. Test hosts and Xcode Previews run inside
/// the app's sandbox container — a unit-test suite once zeroed a live
/// scratchpad that way — so isolated runs are routed to throwaway
/// directories instead.
enum StorageLocation {
    nonisolated static let isIsolatedRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }()

    nonisolated static func directory(named name: String) -> URL {
        if isIsolatedRun {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("antimatter-isolated", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                fatalError("Failed to create isolated storage directory: \(error)")
            }
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Antimatter", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create Application Support directory: \(error)")
        }
        return base
    }
}

/// Atomic text persistence for the scratchpad file, plus a one-generation
/// `.bak`: every overwrite first copies the current file aside, so even a
/// successful write of bad content (or a user's accidental deletion of the
/// primary) leaves the previous good save recoverable.
enum Persistence {
    /// The `<name>.bak` sibling of `url` — a one-generation backup for any
    /// persisted file (scratchpad.md → scratchpad.md.bak, notes.json →
    /// notes.json.bak), not just the scratchpad.
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    /// Checks whether a file exists at the given URL.
    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads `url`, falling back to its `.bak` when the primary file is
    /// missing or unreadable. Returns nil when neither can be read.
    static func read(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return try? String(contentsOf: backupURL(for: url), encoding: .utf8)
    }

    /// Reads binary data from `url`, falling back to its `.bak`.
    /// Returns nil when neither can be read.
    static func readData(from url: URL) -> Data? {
        if let data = try? Data(contentsOf: url) { return data }
        return try? Data(contentsOf: backupURL(for: url))
    }

    /// Reads only the primary file — no fallback. Used to learn what is
    /// actually on disk right now (as opposed to what we last wrote).
    static func readPrimary(from url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Atomically replaces `url` with `text`, preserving the current
    /// contents as the `.bak` first — but only when the primary is still
    /// readable text. Copying garbage over the backup would destroy the
    /// safety net precisely when it matters (post-corruption recovery).
    @discardableResult
    static func write(_ text: String, to url: URL) -> Error? {
        // Failable decode on purpose: `String(decoding:as:)` always succeeds
        // by substituting replacement characters, which would let corrupt
        // bytes pass as "readable".
        writeData(Data(text.utf8), to: url) { primary in
            String(data: primary, encoding: .utf8) != nil
        }
    }

    /// The binary form of `write`. `isValidPrimary` lets callers judge
    /// whether the current file deserves to become the backup (JSON
    /// decodability for timers, for example); an invalid primary is left
    /// unrotated, keeping the previous good generation in place.
    @discardableResult
    static func writeData(
        _ data: Data,
        to url: URL,
        isValidPrimary: ((Data) -> Bool)? = nil
    ) -> Error? {
        let backup = backupURL(for: url)
        if FileManager.default.fileExists(atPath: url.path),
           let primary = try? Data(contentsOf: url),
           isValidPrimary?(primary) ?? true
        {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }
}
