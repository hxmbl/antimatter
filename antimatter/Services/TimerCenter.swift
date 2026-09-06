import Combine
import Foundation
import AppKit
import UserNotifications

struct ActiveTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    let duration: TimeInterval
    let endDate: Date
    let createdAt: Date
    var firedAt: Date?
}

/// Runs scratchpad timers. `.timer 25 soup` schedules a countdown here; the
/// center owns the running list, plays a sound when one elapses, and
/// persists everything so relaunches restore unfinished timers (ones that
/// elapsed while the app was closed come back already marked done, silently).
///
/// Completion reaches the user twice: the in-pane chip and — since the pane
/// is usually hidden when a timer ends — a system notification carrying the
/// timer's name. Clicking the notification reopens the pane and dismisses
/// the chip. Without authorization the sound alone remains.
@MainActor
final class TimerCenter: ObservableObject {
    static let shared = TimerCenter()

    @Published private(set) var timers: [ActiveTimer] = []

    private let fileURL: URL
    private let now: () -> Date
    private var fireTasks: [UUID: Task<Void, Never>] = [:]

    init(fileURL: URL = TimerCenter.defaultFileURL(), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        // Requests scheduled by a previous session are rebuilt below; only
        // stale timer requests are removed — scoped, so any non-timer
        // notification the app might someday post survives the sweep.
        load()
        pruneStaleNotifications()
        for timer in timers {
            scheduleFire(timer, announce: false)
        }
    }

    private func pruneStaleNotifications() {
        let center = UNUserNotificationCenter.current()
        let keep = Set(timers.filter { $0.firedAt == nil }.map(\.id.uuidString))
        center.getPendingNotificationRequests { requests in
            // Scoped to requests this center owns: anything carrying a
            // `timerID` that no live timer references. UUID-shaped requests
            // from other suites (a reminder, say) must survive the sweep —
            // before this check they were pruned here, so reminders silently
            // died on relaunch.
            let stale = requests.compactMap { request -> String? in
                guard let timerID = request.content.userInfo["timerID"] as? String,
                      !keep.contains(timerID)
                else { return nil }
                return request.identifier
            }
            guard !stale.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        StorageLocation.directory(named: "timers").appendingPathComponent("timers.json")
    }

    /// Starts a countdown. Returns false for invalid durations or an
    /// accidental duplicate (pressing return twice on the same line).
    @discardableResult
    func start(duration: TimeInterval, label: String) -> Bool {
        guard duration > 0, duration <= IntentParser.maxDuration else { return false }
        let timestamp = now()
        if timers.contains(where: {
            $0.label == label && $0.duration == duration && timestamp.timeIntervalSince($0.createdAt) < 2
        }) { return false }

        let timer = ActiveTimer(
            id: UUID(),
            label: label,
            duration: duration,
            endDate: timestamp.addingTimeInterval(duration),
            createdAt: timestamp,
            firedAt: nil
        )
        timers.insert(timer, at: 0)
        scheduleFire(timer, announce: true)
        persist()
        Self.requestNotificationAuthorizationIfNeeded()
        DebugLog.log("timer started — \(label.isEmpty ? "unlabelled" : label) (\(Self.format(duration)))")
        return true
    }

    func dismiss(_ id: UUID) {
        timers.removeAll { $0.id == id }
        fireTasks[id]?.cancel()
        fireTasks[id] = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        persist()
    }

    /// `.timer cancel [all]`: stop every running countdown, fired or not.
    func cancelAll() {
        let identifiers = timers.map(\.id.uuidString)
        timers.removeAll()
        for task in fireTasks.values { task.cancel() }
        fireTasks.removeAll()
        if !identifiers.isEmpty {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        persist()
        DebugLog.log("timers cancelled — \(identifiers.count)")
    }

    // MARK: Firing

    private func scheduleFire(_ timer: ActiveTimer, announce: Bool) {
        guard timer.firedAt == nil else { return }
        let delay = timer.endDate.timeIntervalSince(now())
        guard delay > 0 else {
            expire(timer, announce: announce)
            return
        }
        scheduleNotification(for: timer, delay: delay)
        fireTasks[timer.id]?.cancel()
        fireTasks[timer.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expire(timer, announce: announce)
        }
    }

    private func expire(_ timer: ActiveTimer, announce: Bool) {
        fireTasks[timer.id] = nil
        guard let index = timers.firstIndex(where: { $0.id == timer.id }), timers[index].firedAt == nil else { return }
        // A timer restored after its deadline keeps its original end time;
        // one that fires live records "now".
        timers[index].firedAt = max(now(), timer.endDate)
        if announce {
            NSSound(named: "Glass")?.play()
        }
        persist()
    }

    // MARK: System notifications

    /// Test hosts share the app's sandbox container; asking for permission
    /// from tests would burn the system's one-time prompt for real users.
    private nonisolated static let isTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Asks only when the system says we never asked (`notDetermined`) —
    /// no persisted flag, because a flag set before the answer (or set by a
    /// test run in the shared container) permanently silences the feature.
    /// The system itself remembers denials, so this never re-prompts.
    private nonisolated static func requestNotificationAuthorizationIfNeeded() {
        guard !isTestHost else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    private func scheduleNotification(for timer: ActiveTimer, delay: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = timer.label.isEmpty ? "Timer finished" : "\(timer.label) — time's up"
        content.body = Self.format(timer.duration) + " elapsed"
        content.userInfo = ["timerID": timer.id.uuidString]
        // Silent: the Glass sound on live fire is the audible signal; a
        // chime + ring together is noise. The banner still reaches the user
        // when the pane is hidden.
        content.sound = nil
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 0.1), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: trigger))
    }

    /// `5:00`, `1:20:00` — matches the countdown chips.
    nonisolated static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: Persistence

    private func load() {
        // Same recovery rule as the scratchpad: a corrupt or missing primary
        // falls back to the last good generation in timers.json.bak.
        for url in [fileURL, Persistence.backupURL(for: fileURL)] {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode([ActiveTimer].self, from: data)
            else { continue }
            let timestamp = now()
            // Finished chips linger an hour after firing so they can be seen
            // (and dismissed); older ones are dropped.
            timers = stored.filter { timer in
                guard let fired = timer.firedAt else { return true }
                return timestamp.timeIntervalSince(fired) < 60 * 60
            }
            return
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(timers) else { return }
        // Backup rotation skips an undecodable primary: after a recovery
        // from timers.json.bak, the corrupt file must not bury the last
        // good generation.
        Persistence.writeData(data, to: fileURL) { primary in
            (try? JSONDecoder().decode([ActiveTimer].self, from: primary)) != nil
        }
    }
}
