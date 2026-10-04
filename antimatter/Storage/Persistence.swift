import Foundation

/// Where mutable app data lives. Isolated runs (tests, previews) use
/// throwaway directories to avoid touching live data.
enum StorageLocation {
    nonisolated static let isIsolatedRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }()

    /// The `Antimatter` root in the user's Application Support directory.
    /// Injectable so the path layout and the migration can be exercised
    /// against a throwaway root.
    nonisolated static func supportRoot(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("Antimatter", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `…/Antimatter/<name>/` — one subdirectory per store. The `name` used to
    /// be ignored outside tests, which put notes, timers, stopwatches,
    /// reminders, stats and rates in one flat folder.
    nonisolated static func managedDirectory(root: URL, name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    nonisolated static func directory(named name: String) -> URL {
        if isIsolatedRun {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("antimatter-isolated", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        guard let root = supportRoot() else {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        let directory = managedDirectory(root: root, name: name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The legacy sweep enumerates the whole Application Support root, and
        // `directory(named:)` is called from store initialisers *and* from menu
        // actions — with one `window-*.json` per ⌘N press, that listing grows
        // without bound. Run it once per resolved directory per process. Keyed on
        // the path rather than the name so a throwaway root (tests, previews)
        // still gets its own first-run migration.
        if migratedDirectories.insert(directory.path) {
            migrateLegacyFlatFiles(from: root, name: name, into: directory)
            retireLegacyScratchpadIfImported(root: root, name: name, in: directory)
        }
        return directory
    }

    /// Directories whose one-time legacy migration has already run.
    private nonisolated static let migratedDirectories = InsertOnce()

    private final class InsertOnce: @unchecked Sendable {
        private let mutex = NSLock()
        private var seen: Set<String> = []
        /// - Returns: true the first time `key` is offered, false after that.
        func insert(_ key: String) -> Bool {
            mutex.lock()
            defer { mutex.unlock() }
            return seen.insert(key).inserted
        }
    }

    // MARK: - Pre-subdirectory data

    /// Files that sat directly in `…/Antimatter/` before each store got its
    /// own subdirectory: exact names first, then filename prefixes.
    nonisolated static let legacyFlatFiles: [String: (exact: [String], prefixes: [String])] = [
        "notes": (["notes.json", "notes.json.bak"], ["window-"]),
        "scratchpad": (["scratchpad.md"], []),
        "timers": (["timers.json", "timers.json.bak", "timers-pomodoro.json"], []),
        "stopwatches": (["stopwatches.json", "stopwatches.json.bak"], []),
        "reminders": (["reminders.json", "reminders.json.bak"], []),
        "stats": (["stats.json", "stats.json.bak"], []),
        "currency": (["rates.json", "rates.json.bak"], []),
    ]

    /// Moves this store's pre-subdirectory files into `into`.
    ///
    /// Copy-then-delete, and never overwrites an existing destination: a file
    /// already in the subdirectory is newer than anything in the flat root, so
    /// clobbering it would be the one way this migration could lose data. A
    /// failed copy leaves the original in place, so the next launch retries.
    @discardableResult
    nonisolated static func migrateLegacyFlatFiles(
        from root: URL,
        name: String,
        into directory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let mapping = legacyFlatFiles[name],
              let entries = try? fileManager.contentsOfDirectory(
                atPath: root.path
              )
        else { return [] }

        let candidates = entries.filter { entry in
            mapping.exact.contains(entry)
                || mapping.prefixes.contains(where: { entry.hasPrefix($0) })
        }
        guard !candidates.isEmpty else { return [] }

        var moved: [String] = []
        for entry in candidates.sorted() {
            let source = root.appendingPathComponent(entry)
            let destination = directory.appendingPathComponent(entry)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.copyItem(at: source, to: destination)
                // Only drop the original once the copy is actually there.
                guard fileManager.fileExists(atPath: destination.path) else { continue }
                try? fileManager.removeItem(at: source)
                moved.append(entry)
            } catch {
                // Leave the original where it is; a later launch retries.
                continue
            }
        }
        return moved
    }

    /// The pre-Void bootstrap read `scratchpad.md` when the notes file did not
    /// exist yet. That condition is true forever for every extra window (each
    /// one gets a fresh `window-<uuid>.json`), so the stale legacy file used
    /// to be re-imported into each new window. Once any notes file exists the
    /// import already happened (or the note was deliberately dropped), so the
    /// legacy file is retired — renamed aside, never deleted.
    nonisolated static func retireLegacyScratchpadIfImported(
        root: URL,
        name: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) {
        guard name == "scratchpad" else { return }
        let scratchpad = directory.appendingPathComponent("scratchpad.md")
        guard fileManager.fileExists(atPath: scratchpad.path) else { return }
        let notes = managedDirectory(root: root, name: "notes")
        guard hasImportedNotes(in: notes, fileManager: fileManager) else { return }
        let retired = directory.appendingPathComponent("scratchpad.md.imported")
        if fileManager.fileExists(atPath: retired.path) {
            try? fileManager.removeItem(at: retired)
        }
        try? fileManager.moveItem(at: scratchpad, to: retired)
    }

    /// True when the notes subdirectory already holds a non-empty snapshot, so
    /// the legacy scratchpad import can never be the thing that produced it.
    nonisolated static func hasImportedNotes(
        in notes: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: notes.path) else {
            return false
        }
        for entry in entries where entry.hasSuffix(".json") {
            let attributes = try? fileManager.attributesOfItem(
                atPath: notes.appendingPathComponent(entry).path
            )
            if let size = attributes?[.size] as? NSNumber, size.intValue > 0 { return true }
        }
        return false
    }
}

/// Serializes every background write so a burst of mutations to one file lands
/// in submission order instead of racing. Callers used to spawn an
/// unserialized task per mutation, which could persist a stale snapshot after a
/// newer one — dismissed timers and stopwatches reappeared on relaunch.
actor SerialDiskWriter {
    static let shared = SerialDiskWriter()

    /// Writes `data` to `url` once every earlier write to the same URL has
    /// finished. The method has no suspension point, so a writer's mail queue
    /// ordering is the write ordering: a burst from the main actor cannot land
    /// out of sequence.
    @discardableResult
    func write(
        _ data: Data,
        to url: URL,
        isValidPrimary: (@Sendable (Data) -> Bool)? = nil
    ) -> Error? {
        Persistence.writeData(data, to: url, isValidPrimary: isValidPrimary)
    }
}

/// Atomic text persistence with a one-generation `.bak` backup.
enum Persistence {
    nonisolated static func backupURL(for url: URL) -> URL {
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
    ///
    /// Rotation is atomic with respect to the primary: the previous generation
    /// is written to `.bak` with an atomic replace instead of
    /// remove-then-copy, so a crash mid-rotation used to leave *no* backup and
    /// a concurrent reader could catch a half-written one. A per-path lock
    /// keeps the read-rotate-write pair a critical section even when two
    /// writers bypass `SerialDiskWriter`.
    @discardableResult
    nonisolated static func writeData(
        _ data: Data,
        to url: URL,
        isValidPrimary: ((Data) -> Bool)? = nil
    ) -> Error? {
        WriteLocks.shared.withLock(url) {
            let backup = backupURL(for: url)
            if FileManager.default.fileExists(atPath: url.path),
               let primary = try? Data(contentsOf: url),
               isValidPrimary?(primary) ?? true {
                try? primary.write(to: backup, options: .atomic)
            }
            do {
                try data.write(to: url, options: .atomic)
                return nil
            } catch {
                return error
            }
        }
    }
}

/// One lock per file path, so `Persistence.writeData` is serialized even for
/// callers that do not go through `SerialDiskWriter`.
private final class WriteLocks: @unchecked Sendable {
    static let shared = WriteLocks()

    private let mutex = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for url: URL) -> NSLock {
        let key = url.path
        mutex.lock()
        defer { mutex.unlock() }
        // Entries are never dropped: retiring one would race a caller that has
        // fetched the lock but not yet acquired it, and the key set is a handful
        // of files for the life of the process.
        if let existing = locks[key] { return existing }
        let created = NSLock()
        locks[key] = created
        return created
    }

    @discardableResult
    func withLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let lock = lock(for: url)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
