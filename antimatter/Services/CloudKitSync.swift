import CloudKit
import Combine
import CryptoKit
import Foundation
import Security

private let kKeychainService = "com.antimatter.sync-encryption-key"
private let kKeychainAccount = "sync-encryption-key"

struct SyncNote: Identifiable, Equatable {
    let id: UUID
    var text: String
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var isSlot: Bool
    var slotIndex: Int

    init(id: UUID = UUID(), text: String = "", title: String = "", createdAt: Date = Date(), modifiedAt: Date = Date(), isSlot: Bool = false, slotIndex: Int = -1) {
        self.id = id
        self.text = text
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isSlot = isSlot
        self.slotIndex = slotIndex
    }
}

/// E2E-encrypted iCloud sync via CloudKit. Notes are encrypted on-device
/// before upload using AES-GCM.
/// The CloudKit operations the push path needs, abstracted so its failure
/// semantics can be exercised against a fake store in tests.
protocol NoteRecordStore: Sendable {
    func save(_ record: CKRecord) async throws -> CKRecord
    func deleteRecord(withID recordID: CKRecord.ID) async throws
    func records(matching query: CKQuery) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)]
}

/// `CKDatabase` adapter for `pushNotes`.
private struct CKDatabaseRecordStore: NoteRecordStore {
    private let database: CKDatabase

    init(_ database: CKDatabase) {
        self.database = database
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        try await database.save(record)
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws {
        try await database.deleteRecord(withID: recordID)
    }

    func records(matching query: CKQuery) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        let (matchResults, _) = try await database.records(matching: query)
        return matchResults
    }
}

@MainActor
final class CloudKitSync: ObservableObject {
    static let shared = CloudKitSync()

    @Published var isEnabled = false
    @Published var lastSyncDate: Date?
    @Published var syncStatus: SyncStatus = .idle

    enum SyncStatus: Equatable {
        case idle, syncing, error(String)
    }

    private let container: CKContainer?
    private let database: CKDatabase?
    private var encryptionKey: SymmetricKey?

    /// The client-stamped `modifiedAt` of the version of each note this
    /// device last pushed to or applied from iCloud. A fetched record whose
    /// `modifiedAt` differs from the remembered stamp carries changes this
    /// device has not seen; equality means the record holds nothing new.
    /// Persisted so a relaunch doesn't make every record look changed.
    private var lastSyncedModifiedAt: [UUID: Date] = CloudKitSync.loadLastSynced()

    /// Wall-clock of the last pull started from `pullOnShow`, which the
    /// hotkey can trigger many times a minute; each pull is a network fetch.
    private var lastPullAt: Date?

    private static func loadLastSynced() -> [UUID: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: "sync.lastSyncedModifiedAt") ?? [:]
        var out: [UUID: Date] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key), let date = value as? Date {
                out[id] = date
            }
        }
        return out
    }

    private func saveLastSynced() {
        let raw = lastSyncedModifiedAt.reduce(into: [String: Date]()) { $0[$1.key.uuidString] = $1.value }
        UserDefaults.standard.set(raw, forKey: "sync.lastSyncedModifiedAt")
    }

    /// Reads signed entitlements directly so an unprovisioned build degrades
    /// to a surfaced error instead of crashing.
    private static func iCloudContainerIsSignedIn() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var readError: Unmanaged<CFError>?
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            &readError
        ),
            let identifiers = value as? [String],
            identifiers.contains(where: { $0.hasPrefix("iCloud.") })
        else { return false }
        return FileManager.default.ubiquityIdentityToken != nil
    }

    /// Stores the encryption key in the Keychain (not UserDefaults).
    /// `kSecAttrSynchronizable` syncs the item between this app's installs
    /// via iCloud Keychain, so a second Mac can decrypt what the first uploaded.
    private static func saveEncryptionKey(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kKeychainService,
            kSecAttrAccount as String: kKeychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue,
            kSecValueData as String: keyData
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            DebugLog.log("Failed to save encryption key to Keychain: \(status)")
        }
    }

    /// Reads the encryption key, preferring the iCloud-synced item and
    /// migrating pre-upgrade installs: a legacy non-syncing key is re-saved
    /// as synchronizable so other devices inherit it.
    private static func loadEncryptionKey() -> SymmetricKey? {
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kKeychainService,
            kSecAttrAccount as String: kKeychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        if SecItemCopyMatching(syncQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return SymmetricKey(data: data)
        }

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kKeychainService,
            kSecAttrAccount as String: kKeychainAccount,
            kSecReturnData as String: true
        ]
        result = nil
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        saveEncryptionKey(SymmetricKey(data: data))
        return SymmetricKey(data: data)
    }

    init() {
        let provisioned = Self.iCloudContainerIsSignedIn()
        if provisioned {
            container = CKContainer.default()
            database = container?.privateCloudDatabase
        } else {
            container = nil
            database = nil
        }

        encryptionKey = Self.loadEncryptionKey() ?? {
            let newKey = SymmetricKey(size: .bits256)
            Self.saveEncryptionKey(newKey)
            return newKey
        }()

        isEnabled = UserDefaults.standard.bool(forKey: "sync.enabled")
        if isEnabled && !provisioned {
            isEnabled = false
            syncStatus = .error("iCloud unavailable — sign in to iCloud first")
            UserDefaults.standard.set(false, forKey: "sync.enabled")
        }
    }


    private func encrypt(_ text: String) throws -> Data? {
        guard let key = encryptionKey, let data = text.data(using: .utf8) else { return nil }
        let sealed = try AES.GCM.seal(data, using: key)
        return sealed.combined
    }

    private func decrypt(_ data: Data) throws -> String? {
        guard let key = encryptionKey else { return nil }
        let box = try AES.GCM.SealedBox(combined: data)
        let decrypted = try AES.GCM.open(box, using: key)
        return String(data: decrypted, encoding: .utf8)
    }

    /// iCloud Keychain sync is eventual: the key can land a beat after launch.
    /// When the key loaded at startup can't open a record, re-read the Keychain
    /// once — it may have just delivered the synced key — and retry under it.
    /// Restores the previous key if the refreshed one decodes nothing.
    private func decryptAfterReloadingKey(_ data: Data) -> String? {
        guard let refreshed = Self.loadEncryptionKey(),
              refreshed != encryptionKey
        else { return nil }
        let previous = encryptionKey
        encryptionKey = refreshed
        if let text = try? decrypt(data) {
            return text
        }
        encryptionKey = previous
        return nil
    }


    func syncNote(_ note: SyncNote) async {
        guard isEnabled else { return }
        guard let database else {
            syncStatus = .error("iCloud unavailable")
            return
        }
        syncStatus = .syncing

        do {
            // A deterministic recordID keyed on the note id makes every push
            // an in-place update instead of a fresh duplicate in iCloud.
            let recordID = CKRecord.ID(recordName: note.id.uuidString)
            let record = CKRecord(recordType: "Note", recordID: recordID)
            record["noteID"] = note.id.uuidString as CKRecordValue
            record["createdAt"] = note.createdAt as CKRecordValue
            record["modifiedAt"] = note.modifiedAt as CKRecordValue
            record["isSlot"] = note.isSlot as CKRecordValue
            record["slotIndex"] = note.slotIndex as CKRecordValue
            record["title"] = note.title as CKRecordValue

            if let encryptedData = try encrypt(note.text) {
                record["encryptedText"] = encryptedData as CKRecordValue
            }

            try await database.save(record)
            lastSyncDate = Date()
            syncStatus = .idle
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    /// Pushes the given notes and deletions in one pass. `notes` is the
    /// caller's dirty subset, not the whole store — an untouched note is
    /// never re-uploaded. Returns true only when every record landed, so the
    /// caller clears its dirty tracking; on failure nothing is cleared and
    /// the next flush retries.
    @discardableResult
    func sync(notes: [Note], deleting deletedIDs: [UUID]) async -> Bool {
        guard isEnabled else { return false }
        guard let database else {
            syncStatus = .error("iCloud unavailable")
            return false
        }
        return await sync(notes: notes, deleting: deletedIDs, store: CKDatabaseRecordStore(database))
    }

    /// The push half of `sync(notes:deleting:)`, injected with the store so
    /// the failure paths can be tested against a fake.
    @discardableResult
    func sync(notes: [Note], deleting deletedIDs: [UUID], store: any NoteRecordStore) async -> Bool {
        guard isEnabled else { return false }
        syncStatus = .syncing

        do {
            let encryptedNotes: [(id: UUID, createdAt: Date, modifiedAt: Date, isSlot: Bool, slotIndex: Int, title: String, encryptedText: Data?)] = try notes.map { note in
                (note.id, note.createdAt, note.modifiedAt, note.isSlot, note.slotIndex, note.title, try encrypt(note.text))
            }
            try await Self.pushNotes(encryptedNotes, deleting: deletedIDs, store: store)
            lastSyncDate = Date()
            syncStatus = .idle
            for note in notes {
                lastSyncedModifiedAt[note.id] = note.modifiedAt
            }
            saveLastSynced()
            return true
        } catch {
            syncStatus = .error(error.localizedDescription)
            return false
        }
    }

    /// Performs the actual CloudKit I/O off the main thread.
    nonisolated static func pushNotes(
        _ notes: [(id: UUID, createdAt: Date, modifiedAt: Date, isSlot: Bool, slotIndex: Int, title: String, encryptedText: Data?)],
        deleting trashIDs: [UUID],
        store: any NoteRecordStore
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for note in notes {
                group.addTask {
                    let recordID = CKRecord.ID(recordName: note.id.uuidString)
                    let record = CKRecord(recordType: "Note", recordID: recordID)
                    record["noteID"] = note.id.uuidString as CKRecordValue
                    record["createdAt"] = note.createdAt as CKRecordValue
                    record["modifiedAt"] = note.modifiedAt as CKRecordValue
                    record["isSlot"] = note.isSlot as CKRecordValue
                    record["slotIndex"] = note.slotIndex as CKRecordValue
                    record["title"] = note.title as CKRecordValue
                    if let encryptedData = note.encryptedText {
                        record["encryptedText"] = encryptedData as CKRecordValue
                    }
                    try await store.save(record)
                }
            }
            for noteID in trashIDs {
                group.addTask {
                    let predicate = NSPredicate(format: "noteID == %@", noteID.uuidString)
                    let query = CKQuery(recordType: "Note", predicate: predicate)
                    let matchResults = try await store.records(matching: query)
                    for (_, result) in matchResults {
                        switch result {
                        case .success(let record):
                            try await store.deleteRecord(withID: record.recordID)
                        case .failure(let error):
                            // A record that could not be deleted must fail
                            // the push: skipping it lets `sync()` report
                            // success and clear the retry queue while the
                            // record still sits in iCloud.
                            throw error
                        }
                    }
                }
            }
            // `withThrowingTaskGroup` rethrows only when its body throws;
            // child task errors are observed by awaiting `waitForAll()`,
            // which rethrows the first one. Without this, a failed save or
            // delete inside the group is reported as success by `sync()`
            // and the caller clears the retry queue anyway.
            try await group.waitForAll()
        }
    }

    func fetchNotes() async -> [SyncNote] {
        guard isEnabled else { return [] }
        guard let database else {
            syncStatus = .error("iCloud unavailable")
            return []
        }

        do {
            let query = CKQuery(recordType: "Note", predicate: NSPredicate(value: true))
            let (matchResults, _) = try await database.records(matching: query)
            var notes: [SyncNote] = []
            var decryptFailures = 0

            for (_, result) in matchResults {
                guard case .success(let record) = result else { continue }
                guard let noteIDString = record["noteID"] as? String,
                      let noteID = UUID(uuidString: noteIDString),
                      let encryptedData = record["encryptedText"] as? Data,
                      let createdAt = record["createdAt"] as? Date,
                      let modifiedAt = record["modifiedAt"] as? Date,
                      let isSlot = record["isSlot"] as? Bool
                else { continue }
                let slotIndex = (record["slotIndex"] as? Int) ?? -1
                // A record that fails to decrypt means this device's sync key
                // differs from the one that wrote it (iCloud Keychain sync not
                // yet converged, or a true key divergence). Retry once under a
                // freshly-read key; count the rest instead of silently dropping,
                // so a real mismatch is visible to the user.
                guard let text = (try? decrypt(encryptedData)) ?? decryptAfterReloadingKey(encryptedData) else {
                    decryptFailures += 1
                    continue
                }
                let note = SyncNote(id: noteID, text: text, title: record["title"] as? String ?? "",
                                    createdAt: createdAt, modifiedAt: modifiedAt, isSlot: isSlot, slotIndex: slotIndex)
                notes.append(note)
            }

            lastSyncDate = Date()
            if decryptFailures > 0 {
                syncStatus = .error("\(decryptFailures) synced note\(decryptFailures == 1 ? "" : "s") can't be decrypted — iCloud Keychain sync may not have delivered the key yet")
            } else {
                syncStatus = .idle
            }
            return notes
        } catch {
            syncStatus = .error(error.localizedDescription)
            return []
        }
    }

    /// What a pull should do with one remotely fetched note.
    enum RemoteMerge: Equatable {
        /// No local copy and not deleted here: insert it.
        case insert
        /// A version this device has not synced and the local copy is clean:
        /// apply the remote version over it.
        case apply
        /// Both sides changed since the last sync: the server copy wins the
        /// live slot and the local version is kept as a conflict copy.
        case conflict
        /// Nothing to do (already synced, or the local trash/push wins).
        case skip
    }

    /// The merge decision for one fetched note, pure for tests.
    ///
    /// Ordering comes from the server, never from comparing two devices'
    /// clocks: a record the server already holds is by definition newer than
    /// an unpushed local edit. So when both sides changed since the last
    /// sync, the remote version takes the live slot and the local version is
    /// preserved as a conflict copy — divergence is never silently lost, and
    /// no decision ever depends on whether two client clocks agree.
    nonisolated static func merge(
        remoteModifiedAt: Date,
        localModifiedAt: Date?,
        trashed: Bool,
        dirty: Bool,
        lastSynced: Date?
    ) -> RemoteMerge {
        // The local trash wins deletions: a note trashed here must not be
        // resurrected by a pull, and its remote record is deleted on push.
        if trashed { return .skip }
        guard let localModifiedAt else { return .insert }
        if let lastSynced {
            // Bookkept note: equality means this device has already seen
            // exactly this version, whatever any clock says.
            if remoteModifiedAt == lastSynced { return .skip }
            return dirty ? .conflict : .apply
        }
        // No sync bookkeeping yet (install upgraded from a version without
        // stamps): fall back to the legacy modifiedAt comparison. This
        // comparison is between the client stamp in the record and the local
        // note, not between two live client clocks, and only ever runs once
        // per note before the stamp is written.
        if remoteModifiedAt > localModifiedAt {
            return dirty ? .conflict : .apply
        }
        return .skip
    }

    /// The pull half of sync: fetches iCloud notes and merges them into the
    /// store. Anything iCloud has that we don't is added; a version this
    /// device has not synced applies over a clean local copy; a genuine
    /// divergence (both sides changed since the last sync) resolves to the
    /// server copy in the live slot plus the local version filed as a
    /// conflict copy; the local trash wins deletions.
    func pull() async {
        guard isEnabled else { return }
        let remote = await fetchNotes()
        guard !remote.isEmpty else { return }
        let store = NoteStore.shared
        let trashedIDs = Set(store.trash.map(\.id))
        var merged = store.notes
        var conflictCopies: [Note] = []
        var changed = false
        for incoming in remote {
            let idx = merged.firstIndex(where: { $0.id == incoming.id })
            let decision = Self.merge(
                remoteModifiedAt: incoming.modifiedAt,
                localModifiedAt: idx.map { merged[$0].modifiedAt },
                trashed: trashedIDs.contains(incoming.id),
                dirty: store.pendingPushIDs.contains(incoming.id),
                lastSynced: lastSyncedModifiedAt[incoming.id]
            )
            switch decision {
            case .skip:
                continue
            case .insert, .apply, .conflict:
                let note = Note(
                    id: incoming.id, text: incoming.text,
                    createdAt: incoming.createdAt, modifiedAt: incoming.modifiedAt,
                    isSlot: incoming.isSlot, slotIndex: incoming.slotIndex)
                if let idx {
                    if decision == .conflict {
                        let local = merged[idx]
                        // The losing side of a genuine divergence, kept as its
                        // own note instead of evaporating. A fresh id means it
                        // syncs as an independent note on the next push, and a
                        // "Conflict copy" first line makes it visible in the
                        // switcher instead of lurking as a duplicate.
                        conflictCopies.append(Note(
                            text: "Conflict copy\n" + local.text,
                            createdAt: local.createdAt, modifiedAt: Date()))
                    }
                    merged[idx] = note
                } else {
                    merged.insert(note, at: 0)
                }
                // The applied version is now exactly what the server holds,
                // so any local dirty flag for the old version is settled.
                store.clearPendingPush(for: incoming.id)
                lastSyncedModifiedAt[incoming.id] = incoming.modifiedAt
                changed = true
            }
        }
        for copy in conflictCopies {
            merged.insert(copy, at: 0)
            store.markPendingPush(for: copy.id)
        }
        guard changed else { return }
        store.notes = merged
        saveLastSynced()
        // A merge replaces the whole stack, so re-assert the invariant the rest
        // of the app depends on: `activeNoteID` names a note that is in `notes`.
        // Without this a merge can leave the pointer dangling, and every later
        // keystroke would target a note that no longer exists.
        store.repairActiveNotePointer()
        store.flush()
        // A conflict copy is a brand-new local note; push it now rather than
        // waiting for the next local edit to wake the sync pass.
        if !conflictCopies.isEmpty { store.syncIfNeeded() }
    }

    func deleteNote(_ noteID: UUID) async throws {
        guard isEnabled else { return }
        guard let database else {
            throw CloudKitSyncError.unavailable
        }

        do {
            let predicate = NSPredicate(format: "noteID == %@", noteID.uuidString)
            let query = CKQuery(recordType: "Note", predicate: predicate)
            let (matchResults, _) = try await database.records(matching: query)

            for (_, result) in matchResults {
                guard case .success(let record) = result else { continue }
                try await database.deleteRecord(withID: record.recordID)
            }
        } catch {
            throw CloudKitSyncError.deleteFailed(error.localizedDescription)
        }
    }

    func toggleSync() {
        guard container != nil else {
            syncStatus = .error("iCloud unavailable — enable iCloud in the Xcode project first")
            return
        }
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: "sync.enabled")
        if isEnabled {
            syncStatus = .idle
            Task { @MainActor in
                await registerSubscriptionIfNeeded()
                await pull()
            }
        }
    }

    /// The silent-push subscription id for remote Note changes.
    private static let subscriptionID = "antimatter.note-changes"

    /// Registers the CKQuerySubscription once per install, so a push from
    /// another device wakes a pull here instead of waiting for the next
    /// pane-show. Silent (`shouldSendContentAvailable`, no alert UI): sync
    /// must never surface a system notification.
    func registerSubscriptionIfNeeded() async {
        guard isEnabled, let database else { return }
        guard !UserDefaults.standard.bool(forKey: "sync.subscriptionRegistered") else { return }
        let subscription = CKQuerySubscription(
            recordType: "Note",
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            try await database.save(subscription)
            UserDefaults.standard.set(true, forKey: "sync.subscriptionRegistered")
        } catch {
            DebugLog.log("Failed to register sync subscription: \(error.localizedDescription)")
        }
    }

    /// Pull on pane-show, throttled: the hotkey can fire many times a
    /// minute and each pull is a network fetch, so shows within the window
    /// share one pull.
    func pullOnShow() async {
        guard isEnabled else { return }
        if let lastPullAt, Date().timeIntervalSince(lastPullAt) < 15 { return }
        lastPullAt = Date()
        await pull()
    }
}

/// Errors from CloudKit operations.
enum CloudKitSyncError: Error, LocalizedError {
    case unavailable
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud unavailable"
        case .deleteFailed(let msg): return "Delete failed: \(msg)"
        }
    }
}