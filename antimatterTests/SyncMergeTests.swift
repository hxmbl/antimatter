import CloudKit
import Foundation
import Testing
@testable import antimatter

/// STRM-680: server-clock merge decisions for pulled notes. The rules under
/// test: server-last-write-wins with conflict copies on genuine divergence,
/// nothing silently lost, and no decision ever comparing two client clocks.
struct SyncMergeTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func untrashedUnknownNoteIsInserted() {
        let decision = CloudKitSync.merge(
            remoteModifiedAt: t0, localModifiedAt: nil,
            trashed: false, dirty: false, lastSynced: nil)
        #expect(decision == .insert)
    }

    @Test func trashedNoteIsNeverResurrected() {
        let decision = CloudKitSync.merge(
            remoteModifiedAt: t0, localModifiedAt: nil,
            trashed: true, dirty: false, lastSynced: nil)
        #expect(decision == .skip)
    }

    @Test func alreadySyncedVersionIsSkipped() {
        // The stamp matches the record: this device has seen exactly this
        // version, regardless of how the clocks relate.
        let decision = CloudKitSync.merge(
            remoteModifiedAt: t0, localModifiedAt: t0.addingTimeInterval(60),
            trashed: false, dirty: false, lastSynced: t0)
        #expect(decision == .skip)
    }

    @Test func unseenRemoteVersionAppliesOverCleanLocalCopy() {
        let decision = CloudKitSync.merge(
            remoteModifiedAt: t0, localModifiedAt: t0.addingTimeInterval(-60),
            trashed: false, dirty: false, lastSynced: t0.addingTimeInterval(-60))
        #expect(decision == .apply)
    }

    @Test func divergedNoteConflictsInsteadOfLosingEitherSide() {
        // Both sides changed since the last sync: the server copy takes the
        // live slot and the local version becomes a conflict copy.
        let decision = CloudKitSync.merge(
            remoteModifiedAt: t0, localModifiedAt: t0.addingTimeInterval(60),
            trashed: false, dirty: true, lastSynced: t0.addingTimeInterval(-60))
        #expect(decision == .conflict)
    }

    @Test func legacyFallbackKeepsNewerClientStampWhenClean() {
        // No stamp yet (pre-upgrade install): the legacy modifiedAt
        // comparison runs once before the stamp is written.
        let apply = CloudKitSync.merge(
            remoteModifiedAt: t0.addingTimeInterval(60), localModifiedAt: t0,
            trashed: false, dirty: false, lastSynced: nil)
        #expect(apply == .apply)
        let skip = CloudKitSync.merge(
            remoteModifiedAt: t0, localModifiedAt: t0.addingTimeInterval(60),
            trashed: false, dirty: false, lastSynced: nil)
        #expect(skip == .skip)
        let conflict = CloudKitSync.merge(
            remoteModifiedAt: t0.addingTimeInterval(60), localModifiedAt: t0,
            trashed: false, dirty: true, lastSynced: nil)
        #expect(conflict == .conflict)
    }
}

/// STRM-680: the store tracks which notes owe iCloud a record.
@MainActor
struct SyncDirtyTrackingTests {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("notes.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    @Test func createMarksPendingPush() {
        let store = NoteStore(fileURL: tempURL())
        let note = store.create(text: "alpha")
        #expect(store.pendingPushIDs.contains(note.id))
    }

    @Test func editMarksPendingPush() {
        let store = NoteStore(fileURL: tempURL())
        let note = store.create(text: "alpha")
        store.markPushed([(id: note.id, modifiedAt: note.modifiedAt)], deleted: [])
        #expect(store.pendingPushIDs.isEmpty)

        var edited = note
        edited.text = "beta"
        edited.modifiedAt = Date()
        store.activeNote = edited
        #expect(store.pendingPushIDs.contains(note.id))
    }

    @Test func deleteMovesPendingFlagToDeletions() {
        let store = NoteStore(fileURL: tempURL())
        let note = store.create(text: "alpha")
        store.delete(note)
        #expect(!store.pendingPushIDs.contains(note.id))
        #expect(store.pendingDeleteIDs.contains(note.id))
    }

    @Test func restoreMovesDeletionBackToPush() {
        let store = NoteStore(fileURL: tempURL())
        let note = store.create(text: "alpha")
        store.delete(note)
        store.restore(store.trash[0])
        #expect(!store.pendingDeleteIDs.contains(note.id))
        #expect(store.pendingPushIDs.contains(note.id))
    }

    @Test func markPushedKeepsNoteReeditedDuringFlight() {
        let store = NoteStore(fileURL: tempURL())
        let note = store.create(text: "alpha")
        // Push flies with the old stamp; the note changes before it lands.
        var edited = note
        edited.text = "beta"
        edited.modifiedAt = note.modifiedAt.addingTimeInterval(60)
        store.activeNote = edited
        store.markPushed([(id: note.id, modifiedAt: note.modifiedAt)], deleted: [])
        #expect(store.pendingPushIDs.contains(note.id))
    }

    @Test func unsyncedEditsKeepTheirPendingFlagAcrossRelaunch() {
        // A push is attempted and fails; nothing clears the flag, so the
        // relaunch below still has an unpushed edit that owes iCloud a
        // record. (Before the flags were persisted, the flag died here and a
        // pull of a diverged remote version would apply over the edit.)
        let url = tempURL()
        let store = NoteStore(fileURL: url)
        let note = store.create(text: "alpha")
        store.flush()

        let reloaded = NoteStore(fileURL: url)
        #expect(reloaded.pendingPushIDs.contains(note.id))
    }

    @Test func unsyncedDeletionsKeepTheirPendingFlagAcrossRelaunch() {
        let url = tempURL()
        let store = NoteStore(fileURL: url)
        let note = store.create(text: "alpha")
        store.delete(note)
        store.flush()

        let reloaded = NoteStore(fileURL: url)
        #expect(reloaded.pendingDeleteIDs.contains(note.id))
    }

    @Test func pushedFlagsStayClearedAcrossRelaunch() {
        let url = tempURL()
        let store = NoteStore(fileURL: url)
        let note = store.create(text: "alpha")
        store.flush()
        store.markPushed([(id: note.id, modifiedAt: note.modifiedAt)], deleted: [])
        store.flush()

        let reloaded = NoteStore(fileURL: url)
        #expect(!reloaded.pendingPushIDs.contains(note.id))
    }
}

// MARK: - Sync push failure semantics

/// The failure paths of `CloudKitSync.sync`: a CloudKit write that fails must
/// not be acknowledged as successful, or the caller (`NoteStore.markPushed`)
/// clears the retry queue and the change is lost.
private final class FakeNoteRecordStore: @unchecked Sendable, NoteRecordStore {
    var saveError: Error?
    var deleteResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
    private(set) var deletedRecordIDs: [CKRecord.ID] = []

    func save(_ record: CKRecord) async throws -> CKRecord {
        if let saveError { throw saveError }
        return record
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws {
        deletedRecordIDs.append(recordID)
    }

    func records(matching query: CKQuery) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        deleteResults
    }
}

@MainActor
struct SyncPushFailureTests {

    private func disableSync() -> (cloud: CloudKitSync, wasEnabled: Bool) {
        let cloud = CloudKitSync.shared
        let wasEnabled = cloud.isEnabled
        cloud.isEnabled = true
        return (cloud, wasEnabled)
    }

    @Test func failedDeleteFailsThePushInsteadOfAcknowledgingIt() async {
        let (cloud, wasEnabled) = disableSync()
        defer { cloud.isEnabled = wasEnabled }

        let noteID = UUID()
        let recordID = CKRecord.ID(recordName: noteID.uuidString)
        let fake = FakeNoteRecordStore()
        fake.deleteResults = [(recordID, .failure(NSError(domain: "test", code: 1)))]

        let pushed = await cloud.sync(notes: [], deleting: [noteID], store: fake)
        #expect(!pushed)
    }

    @Test func successfulDeleteIsAcknowledged() async {
        let (cloud, wasEnabled) = disableSync()
        defer { cloud.isEnabled = wasEnabled }

        let noteID = UUID()
        let recordID = CKRecord.ID(recordName: noteID.uuidString)
        let fake = FakeNoteRecordStore()
        fake.deleteResults = [(recordID, .success(CKRecord(recordType: "Note", recordID: recordID)))]

        let pushed = await cloud.sync(notes: [], deleting: [noteID], store: fake)
        #expect(pushed)
        #expect(fake.deletedRecordIDs == [recordID])
    }

    @Test func failedSaveFailsThePush() async {
        let (cloud, wasEnabled) = disableSync()
        defer { cloud.isEnabled = wasEnabled }

        let fake = FakeNoteRecordStore()
        fake.saveError = NSError(domain: "test", code: 1)
        let note = Note(id: UUID(), text: "alpha")

        let pushed = await cloud.sync(notes: [note], deleting: [], store: fake)
        #expect(!pushed)
    }
}
