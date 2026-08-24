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
}
