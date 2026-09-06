import Combine
import Foundation
import AppKit
import UserNotifications

struct ActiveReminder: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let message: String
    let createdAt: Date
    var firedAt: Date?
}

/// Runs `.remind` prompts. A reminder rings once at its date: a Glass sound,
/// a transient chip while the pane is open, and a system notification
/// carrying the message. Notifications are scheduled with the system ahead
/// of time, so a reminder fires even when the app is closed. All local.
@MainActor
final class ReminderCenter: ObservableObject {
    static let shared = ReminderCenter()

    @Published private(set) var reminders: [ActiveReminder] = []

    private let fileURL: URL
    private let now: () -> Date
    private var fireTasks: [UUID: Task<Void, Never>] = [:]

    init(fileURL: URL = ReminderCenter.defaultFileURL(), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
        for reminder in reminders where reminder.firedAt == nil {
            scheduleFire(reminder, announce: false)
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        StorageLocation.directory(named: "reminders").appendingPathComponent("reminders.json")
    }

    /// Schedules a one-shot reminder. Returns false for dates already past.
    @discardableResult
    func schedule(message: String, at date: Date) -> Bool {
        let timestamp = now()
        guard !message.isEmpty, date > timestamp else { return false }
        let reminder = ActiveReminder(
            id: UUID(),
            date: date,
            message: message,
            createdAt: timestamp,
            firedAt: nil
        )
        reminders.insert(reminder, at: 0)
        scheduleFire(reminder, announce: true)
        persist()
        Self.requestNotificationAuthorizationIfNeeded()
        return true
    }

    func dismiss(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        fireTasks[id]?.cancel()
        fireTasks[id] = nil
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        persist()
    }

    /// `.reminder cancel [all]`: cancel every pending reminder, fired or not.
    func cancelAll() {
        let identifiers = reminders.map(\.id.uuidString)
        reminders.removeAll()
        for task in fireTasks.values { task.cancel() }
        fireTasks.removeAll()
        if !identifiers.isEmpty {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        persist()
    }

    // MARK: Firing

    private func scheduleFire(_ reminder: ActiveReminder, announce: Bool) {
        guard reminder.firedAt == nil else { return }
        let delay = reminder.date.timeIntervalSince(now())
        guard delay > 0 else {
            fire(reminder, announce: announce)
            return
        }
        scheduleNotification(for: reminder, delay: delay)
        fireTasks[reminder.id]?.cancel()
        fireTasks[reminder.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.fire(reminder, announce: announce)
        }
    }

    private func fire(_ reminder: ActiveReminder, announce: Bool) {
        fireTasks[reminder.id] = nil
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }),
              reminders[index].firedAt == nil
        else { return }
        reminders[index].firedAt = max(now(), reminder.date)
        if announce {
            NSSound(named: "Glass")?.play()
        }
        persist()
    }

    private func scheduleNotification(for reminder: ActiveReminder, delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = reminder.message
        content.userInfo = ["reminderID": reminder.id.uuidString]
        content.sound = nil // the Glass chime on live fire is the audible signal
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 0.1), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger))
    }

    /// Test hosts share the app's sandbox container; asking for permission
    /// from tests would burn the system's one-time prompt for real users.
    private nonisolated static let isTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private nonisolated static func requestNotificationAuthorizationIfNeeded() {
        guard !isTestHost else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    // MARK: Persistence

    private func load() {
        for url in [fileURL, Persistence.backupURL(for: fileURL)] {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode([ActiveReminder].self, from: data),
                  !stored.isEmpty
            else { continue }
            let timestamp = now()
            reminders = stored.filter { reminder in
                guard let fired = reminder.firedAt else { return true }
                return timestamp.timeIntervalSince(fired) < 60 * 60
            }
            return
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        Persistence.writeData(data, to: fileURL) { primary in
            (try? JSONDecoder().decode([ActiveReminder].self, from: primary)) != nil
        }
    }

    /// `45s`, `12m`, `2h`, `3d` — fits the chip.
    nonisolated static func format(_ interval: TimeInterval) -> String {
        if interval >= 86_400 * 2 {
            return "\(Int(interval / 86_400))d"
        }
        if interval >= 3_600 {
            return "\(Int(interval / 3_600))h"
        }
        if interval >= 60 {
            return "\(Int(interval / 60))m"
        }
        return "\(Int(interval.rounded()))s"
    }
}