import Foundation
import Testing
@testable import antimatter

/// STRM-683: the retired ⌘N extra-window feature left one `window-*.json`
/// store per extra window next to `notes.json`. First launch after the
/// removal folds them into the single store; the originals are renamed
/// aside, never deleted.
@MainActor
struct LegacyWindowStoreMigrationTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeWindowStore(_ dir: URL, name: String, notes: [Note], trash: [Note] = []) throws {
        let snapshot = NoteStore.Snapshot(notes: notes, trash: trash, activeNoteID: notes.first?.id)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: dir.appendingPathComponent(name))
    }

    @Test func windowNotesFoldIntoTheMainStore() throws {
        let dir = tempDir()
        let windowNote = Note(text: "from the extra window")
        try writeWindowStore(dir, name: "window-\(UUID().uuidString).json", notes: [windowNote])

        let store = NoteStore(fileURL: dir.appendingPathComponent("notes.json"))
        #expect(store.notes.contains(where: { $0.id == windowNote.id && $0.text == "from the extra window" }))
    }

    @Test func consumedStoreIsRenamedAsideNeverDeleted() throws {
        let dir = tempDir()
        let name = "window-\(UUID().uuidString).json"
        try writeWindowStore(dir, name: name, notes: [Note(text: "keep me")])

        _ = NoteStore(fileURL: dir.appendingPathComponent("notes.json"))
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(!entries.contains(name))
        #expect(entries.contains(name + ".migrated"))
    }

    @Test func autoCreatedEmptyWindowNotesAreSkipped() throws {
        let dir = tempDir()
        try writeWindowStore(dir, name: "window-\(UUID().uuidString).json", notes: [Note(text: "")])

        let store = NoteStore(fileURL: dir.appendingPathComponent("notes.json"))
        // Only the store's own first note, no imported empty.
        #expect(store.notes.allSatisfy { !$0.text.isEmpty || $0.id == store.activeNoteID })
        #expect(store.notes.count == 1)
    }

    @Test func slotCollisionDemotesTheImportedNote() throws {
        let dir = tempDir()
        let main = NoteStore(fileURL: dir.appendingPathComponent("notes.json"))
        let mainSlot = main.note(forSlot: 2)
        // Saves are debounced; the second store below reads from disk.
        main.flush()

        let windowSlot = Note(text: "other slot two", isSlot: true, slotIndex: 2)
        try writeWindowStore(dir, name: "window-\(UUID().uuidString).json", notes: [windowSlot])

        let store = NoteStore(fileURL: dir.appendingPathComponent("notes.json"))
        let imported = store.notes.first(where: { $0.id == windowSlot.id })
        #expect(imported != nil)
        #expect(imported?.isSlot == false)
        // The main store's pin survives untouched.
        #expect(store.notes.first(where: { $0.id == mainSlot.id })?.isSlot == true)
        #expect(store.notes.filter { $0.isSlot && $0.slotIndex == 2 }.count == 1)
    }

    @Test func windowTrashIsImported() throws {
        let dir = tempDir()
        let trashed = Note(text: "thrown away in the extra window")
        try writeWindowStore(dir, name: "window-\(UUID().uuidString).json", notes: [], trash: [trashed])

        let store = NoteStore(fileURL: dir.appendingPathComponent("notes.json"))
        #expect(store.trash.contains(where: { $0.id == trashed.id }))
    }
}
