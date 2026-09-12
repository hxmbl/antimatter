import Foundation
import Testing
@testable import antimatter

/// Tests for the atomic-write-plus-backup persistence layer.
struct PersistenceTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-persist-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDirectory() throws -> URL {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writeThenReadRoundTrips() throws {
        let url = try makeDirectory().appendingPathComponent("scratchpad.md")
        #expect(Persistence.write("hello", to: url) == nil)
        #expect(Persistence.read(from: url) == "hello")
    }

    @Test func overwritingKeepsPreviousGenerationAsBak() throws {
        let url = try makeDirectory().appendingPathComponent("scratchpad.md")
        #expect(Persistence.write("first", to: url) == nil)
        #expect(Persistence.write("second", to: url) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        #expect(try String(contentsOf: Persistence.backupURL(for: url), encoding: .utf8) == "first")
    }

    @Test func unreadablePrimaryFallsBackToBak() throws {
        let url = try makeDirectory().appendingPathComponent("scratchpad.md")
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
struct NoteStoreWritePathTests {

    private func notesURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-notestore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("notes.json")
    }

    @Test func failedFlushSurfacesAnError() {
        // Parent directory absent → every write fails.
        let doomedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-missing-\(UUID().uuidString)")
            .appendingPathComponent("notes.json")
        let store = NoteStore(fileURL: doomedURL)
        var note = store.activeNote
        note.text = "unsavable"
        store.activeNote = note
        store.flush()
        #expect(store.saveError != nil)
    }

    @Test func successfulFlushLeavesNoError() {
        let store = NoteStore(fileURL: notesURL())
        var note = store.activeNote
        note.text = "savable"
        store.activeNote = note
        store.flush()
        #expect(store.saveError == nil)
    }

    @Test func firstEverFlushCreatesNoStrayBackup() throws {
        let url = notesURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = NoteStore(fileURL: url)
        var note = store.activeNote
        note.text = "one"
        store.activeNote = note
        store.flush()
        #expect(Persistence.fileExists(at: url))
        #expect(!Persistence.fileExists(at: Persistence.backupURL(for: url)))
    }

    @Test func twoGenerationsTrailOneBackup() throws {
        let url = notesURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = NoteStore(fileURL: url)
        var note = store.activeNote
        note.text = "first generation"
        store.activeNote = note
        store.flush()          // primary = one generation, no backup yet
        note.text = "second generation"
        store.activeNote = note
        store.flush()          // backup = first generation, primary = second
        let backupText = try String(contentsOf: Persistence.backupURL(for: url), encoding: .utf8)
        #expect(backupText.contains("first generation"))
        let primaryText = try String(contentsOf: url, encoding: .utf8)
        #expect(primaryText.contains("second generation"))
    }

    @Test func deletedPrimaryRecoversFromTheBackup() {
        // User accidentally deletes notes.json; the .bak trails one
        // generation behind, so loading lands on the PREVIOUS good save.
        let url = notesURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = NoteStore(fileURL: url)
        var note = store.activeNote
        note.text = "first generation"
        store.activeNote = note
        store.flush()
        note.text = "second generation"
        store.activeNote = note
        store.flush()   // now the .bak holds the first generation

        try? FileManager.default.removeItem(at: url)
        let reloaded = NoteStore(fileURL: url)
        #expect(reloaded.activeNote.text == "first generation")
    }
}
