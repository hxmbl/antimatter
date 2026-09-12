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

    init(id: UUID = UUID(), text: String = "", title: String = "", createdAt: Date = Date(), modifiedAt: Date = Date(), isSlot: Bool = false) {
        self.id = id
        self.text = text
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isSlot = isSlot
    }
}

/// E2E-encrypted iCloud sync via CloudKit. Notes are encrypted on-device
/// before upload using AES-GCM.
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
    private let encryptionKey: SymmetricKey?

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
    private static func saveEncryptionKey(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kKeychainService,
            kSecAttrAccount as String: kKeychainAccount,
            kSecValueData as String: keyData
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            DebugLog.log("Failed to save encryption key to Keychain: \(status)")
        }
    }

    private static func loadEncryptionKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kKeychainService,
            kSecAttrAccount as String: kKeychainAccount,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
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

    /// Pushes all notes and deletions in one pass.
    func sync(notes: [Note], trash: [Note]) async {
        guard isEnabled else { return }
        guard let database else {
            syncStatus = .error("iCloud unavailable")
            return
        }
        syncStatus = .syncing

        do {
            var encryptedNotes: [(Note, Data?)] = []
            for note in notes {
                let encrypted = try encrypt(note.text)
                encryptedNotes.append((note, encrypted))
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (note, encryptedData) in encryptedNotes {
                    group.addTask {
                        let recordID = CKRecord.ID(recordName: note.id.uuidString)
                        let record = CKRecord(recordType: "Note", recordID: recordID)
                        record["noteID"] = note.id.uuidString as CKRecordValue
                        record["createdAt"] = note.createdAt as CKRecordValue
                        record["modifiedAt"] = note.modifiedAt as CKRecordValue
                        record["isSlot"] = note.isSlot as CKRecordValue
                        record["title"] = note.title as CKRecordValue
                        if let encryptedData {
                            record["encryptedText"] = encryptedData as CKRecordValue
                        }
                        try await database.save(record)
                    }
                }
                for voided in trash {
                    group.addTask {
                        try await CloudKitSync.shared.deleteNote(voided.id)
                    }
                }
            }
            lastSyncDate = Date()
            syncStatus = .idle
        } catch {
            syncStatus = .error(error.localizedDescription)
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

            for (_, result) in matchResults {
                guard case .success(let record) = result else { continue }
                guard let noteIDString = record["noteID"] as? String,
                      let noteID = UUID(uuidString: noteIDString),
                      let encryptedData = record["encryptedText"] as? Data,
                      let text = try decrypt(encryptedData),
                      let createdAt = record["createdAt"] as? Date,
                      let modifiedAt = record["modifiedAt"] as? Date,
                      let isSlot = record["isSlot"] as? Bool else { continue }

                let title = record["title"] as? String ?? ""
                let note = SyncNote(id: noteID, text: text, title: title, createdAt: createdAt, modifiedAt: modifiedAt, isSlot: isSlot)
                notes.append(note)
            }

            lastSyncDate = Date()
            return notes
        } catch {
            syncStatus = .error(error.localizedDescription)
            return []
        }
    }

    /// The pull half of sync: fetches iCloud notes and merges them into the
    /// store. Local wins on tie, newer `modifiedAt` wins on conflict;
    /// anything iCloud has that we don't is added.
    func pull() async {
        guard isEnabled else { return }
        let remote = await fetchNotes()
        guard !remote.isEmpty else { return }
        let store = NoteStore.shared
        var merged = store.notes
        for incoming in remote {
            let note = Note(
                id: incoming.id, text: incoming.text,
                createdAt: incoming.createdAt, modifiedAt: incoming.modifiedAt,
                isSlot: incoming.isSlot)
            if let idx = merged.firstIndex(where: { $0.id == incoming.id }) {
                if incoming.modifiedAt > merged[idx].modifiedAt {
                    merged[idx] = note
                }
            } else {
                merged.insert(note, at: 0)
            }
        }
        store.notes = merged
        store.flush()
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
        }
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