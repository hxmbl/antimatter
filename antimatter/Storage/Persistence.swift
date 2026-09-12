import Foundation

/// Where mutable app data lives. Isolated runs (tests, previews) use
/// throwaway directories to avoid touching live data.
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

/// Atomic text persistence with a one-generation `.bak` backup.
enum Persistence {
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads `url`, falling back to `.bak` when the primary is missing.
    static func read(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return try? String(contentsOf: backupURL(for: url), encoding: .utf8)
    }

    /// Reads binary data from `url`, falling back to `.bak`.
    static func readData(from url: URL) -> Data? {
        if let data = try? Data(contentsOf: url) { return data }
        return try? Data(contentsOf: backupURL(for: url))
    }

    /// Reads only the primary file — no fallback.
    static func readPrimary(from url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Atomically replaces `url` with `text`, preserving a `.bak` backup.
    @discardableResult
    static func write(_ text: String, to url: URL) -> Error? {
        // Failable decode on purpose: `String(decoding:as:)` always succeeds
        // by substituting replacement characters.
        writeData(Data(text.utf8), to: url) { primary in
            String(data: primary, encoding: .utf8) != nil
        }
    }

    /// The binary form of `write`. `isValidPrimary` controls backup rotation.
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
