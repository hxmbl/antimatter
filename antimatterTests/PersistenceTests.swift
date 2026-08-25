import Foundation
import Testing
@testable import antimatter

/// Tests for the atomic-write-plus-backup helper behind `ScratchStore`.
struct PersistenceTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-persist-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDirectory() -> URL {
        let dir = tempDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writeThenReadRoundTrips() {
        let url = makeDirectory().appendingPathComponent("scratchpad.md")
        #expect(Persistence.write("hello", to: url) == nil)
        #expect(Persistence.read(from: url) == "hello")
    }

    @Test func overwritingKeepsPreviousGenerationAsBak() throws {
        let url = makeDirectory().appendingPathComponent("scratchpad.md")
        Persistence.write("first", to: url)
        Persistence.write("second", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        #expect(try String(contentsOf: Persistence.backupURL(for: url), encoding: .utf8) == "first")
    }

    @Test func unreadablePrimaryFallsBackToBak() throws {
        let url = makeDirectory().appendingPathComponent("scratchpad.md")
        try "salvage".write(to: Persistence.backupURL(for: url), atomically: true, encoding: .utf8)
        // Invalid UTF-8 makes the primary unreadable as text.
        try Data([0xFF]).write(to: url)
        #expect(Persistence.read(from: url) == "salvage")
    }

    @Test func missingEverythingReadsAsNil() {
        #expect(Persistence.read(from: tempDir().appendingPathComponent("none.md")) == nil)
    }

    @Test func unwritableDestinationReportsErrorInsteadOfThrowing() {
        // Parent directory does not exist, so the atomic write must fail.
        let url = tempDir().appendingPathComponent("nested").appendingPathComponent("scratchpad.md")
        #expect(Persistence.write("x", to: url) != nil)
    }
}

@MainActor
struct SaveFailureTests {

    @Test func failedFlushSurfacesAnError() {
        // Parent directory absent → every write fails.
        let doomedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-missing-\(UUID().uuidString)")
            .appendingPathComponent("scratchpad.md")
        let store = ScratchStore(fileURL: doomedURL)
        store.text = "unsavable"
        store.flush()
        #expect(store.saveError != nil)
    }

    @Test func successfulFlushLeavesNoError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-ok-\(UUID().uuidString).md")
        let store = ScratchStore(fileURL: url)
        store.text = "savable"
        store.flush()
        #expect(store.saveError == nil)
    }

    @Test func firstEverFlushCreatesNoStrayBackup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-fresh-\(UUID().uuidString).md")
        let store = ScratchStore(fileURL: url)
        store.text = "one"
        store.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: Persistence.backupURL(for: url).path))
    }

    @Test func unchangedFlushDoesNotChurnTheBackup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-churn-\(UUID().uuidString).md")
        let backup = Persistence.backupURL(for: url)
        let store = ScratchStore(fileURL: url)

        store.text = "one"
        store.flush()          // primary = one, no backup yet
        store.text = "two"
        store.flush()          // backup = one, primary = two
        #expect(try String(contentsOf: backup, encoding: .utf8) == "one")

        store.text = "two"
        store.flush()          // disk already agrees — skipped
        #expect(try String(contentsOf: backup, encoding: .utf8) == "one")
        #expect(try String(contentsOf: url, encoding: .utf8) == "two")
    }

    @Test func externalCorruptionRecoversFromTheBackup() {
        // The watcher fires after the primary was clobbered elsewhere:
        // disk truth wins over unsaved local typing. The .bak always trails
        // one generation behind, so recovery lands on the PREVIOUS good
        // content — that is the guarantee, by design.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-adopt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scratchpad.md")

        let store = ScratchStore(fileURL: url)
        store.text = "first generation"
        store.flush()
        store.text = "second generation"
        store.flush()   // now the .bak holds the first generation

        try? Data([0xFF]).write(to: url)  // corrupt the primary behind the app's back
        store.text = "unsaved typing"     // keystrokes that never reached disk
        store.adoptExternalChange()

        #expect(store.text == "first generation")
        store.flush()
        #expect((try? String(contentsOf: url, encoding: .utf8)) == "first generation")
    }

    @Test func corruptPrimaryIsNeverRotatedIntoTheBackup() throws {
        // The .bak must survive a recovery flush: copying the corrupt
        // primary over it would destroy the safety net exactly when needed.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-rotate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scratchpad.md")
        let backup = Persistence.backupURL(for: url)

        let store = ScratchStore(fileURL: url)
        store.text = "first"
        store.flush()
        store.text = "second"
        store.flush()                      // bak = "first", primary = "second"

        try? Data([0xFF]).write(to: url)   // primary corrupted externally
        store.adoptExternalChange()        // rescues "first" from the bak
        store.flush()

        #expect((try? String(contentsOf: url, encoding: .utf8)) == "first")
        #expect((try? String(contentsOf: backup, encoding: .utf8)) == "first") // not garbage
    }

    @Test func corruptionWithoutBackupStillRecoversOnFlush() {
        // No .bak exists (single-generation history): after adoption sees an
        // unreadable primary, the next flush must restore anyway — a naive
        // skip-if-synced check would preserve the garbage forever.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-nobak-\(UUID().uuidString).md")

        let store = ScratchStore(fileURL: url)
        store.text = "only generation"
        store.flush()

        try? Data([0xFF]).write(to: url)   // clobbered; nothing to rescue
        store.adoptExternalChange()
        store.flush()

        #expect(store.text == "only generation")
        #expect((try? String(contentsOf: url, encoding: .utf8)) == "only generation")
    }
}
