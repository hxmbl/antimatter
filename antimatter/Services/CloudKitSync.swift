import CloudKit
import Combine
import CryptoKit
import Foundation
import Security

/// Represents a synced note record.
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

/// E2E-encrypted iCloud sync via CloudKit.
/// Notes are encrypted on-device before upload using AES-GCM.
/// The container is created lazily and only when iCloud is actually
/// available, so a build without the iCloud entitlement or a signed-out
/// account degrades to a surfaced error instead of a crash.
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

    /// `CKContainer.default()` throws an Objective-C exception — a hard crash
    /// in Swift — when the app isn't signed with an iCloud container
    /// entitlement, and `ubiquityIdentityToken` alone can't tell a
    /// provisioned app apart from a bare signed test host. Read the signed
    /// entitlements directly so an unprovisioned build degrades to a surfaced
    /// "iCloud unavailable" state instead of crashing.
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

    init() {
        let provisioned = Self.iCloudContainerIsSignedIn()
        if provisioned {
            container = CKContainer.default()
            database = container?.privateCloudDatabase
        } else {
            container = nil
            database = nil
        }

        if let existingKeyData = UserDefaults.standard.data(forKey: "sync.encryptionKey") {
            encryptionKey = SymmetricKey(data: existingKeyData)
        } else {
            let newKey = SymmetricKey(size: .bits256)
            UserDefaults.standard.set(newKey.withUnsafeBytes { Data($0) }, forKey: "sync.encryptionKey")
            encryptionKey = newKey
        }

        isEnabled = UserDefaults.standard.bool(forKey: "sync.enabled")
        if isEnabled && !provisioned {
            isEnabled = false
            syncStatus = .error("iCloud unavailable — sign in to iCloud first")
            UserDefaults.standard.set(false, forKey: "sync.enabled")
        }
    }

    // MARK: - Encryption

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

    // MARK: - Sync Operations

    func syncNote(_ note: SyncNote) async {
        guard isEnabled else { return }
        guard let database else {
            syncStatus = .error("iCloud unavailable")
            return
        }
        syncStatus = .syncing

        do {
            let record = CKRecord(recordType: "Note")
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

    /// Pushes all notes (with their deletions handled via `deletedNoteIDs`)
    /// in one pass. Deleted (Void) notes are removed from iCloud so trashing
    /// on one Mac reflects on the others.
    func sync(notes: [Note], trash: [Note]) async {
        guard isEnabled else { return }
        guard let database else {
            syncStatus = .error("iCloud unavailable")
            return
        }
        syncStatus = .syncing

        do {
            for note in notes {
                let record = CKRecord(recordType: "Note")
                record["noteID"] = note.id.uuidString as CKRecordValue
                record["createdAt"] = note.createdAt as CKRecordValue
                record["modifiedAt"] = note.modifiedAt as CKRecordValue
                record["isSlot"] = note.isSlot as CKRecordValue
                record["title"] = note.title as CKRecordValue
                if let encryptedData = try encrypt(note.text) {
                    record["encryptedText"] = encryptedData as CKRecordValue
                }
                try await database.save(record)
            }
            // Nothing in the Void should exist in the cloud either.
            for voided in trash {
                await deleteNote(voided.id)
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

    func deleteNote(_ noteID: UUID) async {
        guard isEnabled else { return }
        guard let database else {
            syncStatus = .error("iCloud unavailable")
            return
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
            syncStatus = .error(error.localizedDescription)
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
