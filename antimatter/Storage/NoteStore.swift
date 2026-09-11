import Combine
import Foundation
import SwiftUI

@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published var notes: [Note] = []
    @Published var activeNoteID: UUID = UUID()
    @Published var trash: [Note] = []
    @Published var saveError: Error?
    @Published var saveErrorToken: Int = 0

    private let fileURL: URL
    private let syncEnabled: Bool
    private var saveTask: Task<Void, Never>?
    private var voidTask: Task<Void, Never>?

    var activeNote: Note {
        get { notes.first { $0.id == activeNoteID } ?? Note() }
        set {
            if let idx = notes.firstIndex(where: { $0.id == activeNoteID }) {
                notes[idx] = newValue
                scheduleSave()
            }
        }
    }

    var activeText: Binding<String> {
        Binding(
            get: { self.activeNote.text },
            set: { newVal in
                var note = self.activeNote
                note.text = newVal
                note.modifiedAt = Date()
                self.activeNote = note
                self.textDidChange()
            }
        )
    }

    init(fileURL: URL = NoteStore.defaultFileURL(), syncEnabled: Bool = true) {
        self.fileURL = fileURL
        self.syncEnabled = syncEnabled
        // Migration: if notes.json doesn't exist but scratchpad.md does, import it.
        let scratchURL = StorageLocation.directory(named: "scratchpad")
            .appendingPathComponent("scratchpad.md")
        if !Persistence.fileExists(at: fileURL),
           let text = Persistence.read(from: scratchURL),
           !text.isEmpty {
            let imported = Note(text: text)
            notes = [imported]
            activeNoteID = imported.id
            flush()
        } else {
            load()
            if notes.isEmpty {
                let first = Note()
                notes = [first]
                activeNoteID = first.id
            } else if !notes.contains(where: { $0.id == activeNoteID }) {
                // load() restores the sliced active note from the snapshot;
                // only fall back to the front of the stack when absent.
                activeNoteID = notes[0].id
            }
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        StorageLocation.directory(named: "notes").appendingPathComponent("notes.json")
    }

    // MARK: - CRUD

    func create(text: String = "") -> Note {
        let note = Note(text: text)
        notes.insert(note, at: 0)
        activeNoteID = note.id
        scheduleSave()
        return note
    }

    func delete(_ note: Note) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let removed = notes.remove(at: idx)
        var deleted = removed
        deleted.modifiedAt = Date()
        trash.append(deleted)
        scheduleVoidPrune()
        if activeNoteID == note.id {
            activeNoteID = notes.first?.id ?? create().id
        }
        scheduleSave()
    }

    func restore(_ note: Note) {
        guard let idx = trash.firstIndex(where: { $0.id == note.id }) else { return }
        let restored = trash.remove(at: idx)
        notes.insert(restored, at: 0)
        scheduleSave()
    }

    func emptyVoid() {
        trash.removeAll()
        scheduleSave()
    }

    func promoteToSlot(_ note: Note, at index: Int) {
        guard (0...8).contains(index) else { return }
        if let existing = notes.first(where: { $0.isSlot && $0.slotIndex == index }) {
            notes.removeAll { $0.id == existing.id }
        } else if let existing = trash.first(where: { $0.isSlot && $0.slotIndex == index }) {
            trash.removeAll { $0.id == existing.id }
        }
        var slotNote = note
        slotNote.isSlot = true
        slotNote.slotIndex = index
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = slotNote
        }
        scheduleSave()
    }

    func cycleNote(direction: Int) {
        guard !notes.isEmpty else { return }
        if let idx = notes.firstIndex(where: { $0.id == activeNoteID }) {
            let newIdx = (idx + direction + notes.count) % notes.count
            activeNoteID = notes[newIdx].id
        }
    }

    func slotNotes() -> [Note] {
        (0..<9).compactMap { i in
            notes.first { $0.isSlot && $0.slotIndex == i }
        }
    }

    // MARK: - Persistence

    /// What actually lands on disk: the note stack, The Void, and the active
    /// selection, so a relaunch restores exactly where the user was.
    /// Internal so tests can verify persistence end-to-end.
    struct Snapshot: Codable, Equatable {
        var notes: [Note]
        var trash: [Note]
        var activeNoteID: UUID?
    }

    private func textDidChange() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        do {
            let snapshot = Snapshot(notes: notes, trash: trash, activeNoteID: activeNoteID)
            let data = try JSONEncoder().encode(snapshot)
            let err = Persistence.writeData(data, to: fileURL)
            if let err { throw err }
            saveError = nil
            syncIfNeeded()
        } catch {
            saveError = error
            saveErrorToken += 1
        }
    }

    /// Pushes every note to iCloud when sync is switched on. Extra ⌘N
    /// scratchpads are excluded — they have their own file and should not
    /// collide with the main store's CloudKit snapshot.
    func syncIfNeeded() {
        guard syncEnabled, CloudKitSync.shared.isEnabled else { return }
        let toSync = notes
        let void = trash
        Task { @MainActor in
            await CloudKitSync.shared.sync(notes: toSync, trash: void)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.flush()
        }
    }

    private func load() {
        guard let data = Persistence.readData(from: fileURL) else { return }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            notes = snapshot.notes
            trash = snapshot.trash
            if let id = snapshot.activeNoteID, notes.contains(where: { $0.id == id }) {
                activeNoteID = id
            }
        } else if let legacy = try? JSONDecoder().decode([Note].self, from: data) {
            // Pre-Void build wrote a bare [Note] array; keep that data.
            notes = legacy
        } else {
            return
        }
        let cutoff = Date().addingTimeInterval(-36 * 3600)
        trash.removeAll { $0.modifiedAt < cutoff }
    }

    private func scheduleVoidPrune() {
        voidTask?.cancel()
        let cutoff = Date().addingTimeInterval(-36 * 3600)
        let staleCount = trash.filter { $0.modifiedAt < cutoff }.count
        guard staleCount > 0 else { return }
        voidTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.trash.removeAll { $0.modifiedAt < cutoff }
            self?.scheduleSave()
        }
    }
}