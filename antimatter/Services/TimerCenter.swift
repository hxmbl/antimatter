import Combine
import Foundation
import AppKit
import UserNotifications

struct ActiveTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var name: String?
    let duration: TimeInterval
    let endDate: Date
    let createdAt: Date
    var firedAt: Date?
    var fullScreen: Bool
}

/// A running `.pomodoro` session, persisted so the cycle survives relaunch.
struct PomodoroSession: Codable, Equatable {
    /// 1-based current cycle.
    var cycle: Int
    /// Total cycles requested.
    var cycles: Int
    /// True for a work phase, false for a break phase.
    var isWork: Bool
    /// When the current phase began, for recomputing the remainder.
    var phaseStartedAt: Date
    /// Work phase length.
    var workDuration: TimeInterval
    /// Break phase length.
    var breakDuration: TimeInterval

    var label: String {
        let phase = isWork ? "Work" : "Break"
        return "Pomodoro \(cycle)/\(cycles) — \(phase)"
    }
}

/// Runs scratchpad timers. `.timer 25 soup` schedules a countdown.
/// Persists so relaunches restore unfinished timers.
@MainActor
final class TimerCenter: ObservableObject {
    static let shared = TimerCenter()

    @Published private(set) var timers: [ActiveTimer] = []

    private let fileURL: URL
    private let pomodoroFileURL: URL
    private let now: () -> Date
    private var fireTasks: [UUID: Task<Void, Never>] = [:]
    private var pomodoroTask: Task<Void, Never>?

    init(fileURL: URL = TimerCenter.defaultFileURL(), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        // Sibling of the timers file, not of its directory: multiple
        // TimerCenters (each test, each window) must never share one pomodoro
        // file — a leftover session would resume in every instance.
        self.pomodoroFileURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-pomodoro.json")
        self.now = now
        load()
        pruneStaleNotifications()
        for timer in timers {
            scheduleFire(timer, announce: false)
        }
        resumePomodoroIfNeeded()
    }

    private func pruneStaleNotifications() {
        let keep = Set(timers.filter { $0.firedAt == nil }.map(\.id.uuidString))
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
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
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        StorageLocation.directory(named: "timers").appendingPathComponent("timers.json")
    }

    /// Starts a countdown. Returns false for invalid durations or duplicates.
    @discardableResult
    func start(duration: TimeInterval, label: String, name: String? = nil, fullScreen: Bool = false) -> Bool {
        start(duration: duration, label: label, name: name, fullScreen: fullScreen, announce: true)
    }

    /// The shared start path. `announce: false` keeps the timer silent.
    @discardableResult
    private func start(duration: TimeInterval, label: String, name: String? = nil, fullScreen: Bool = false, announce: Bool) -> Bool {
        guard duration > 0, duration <= IntentParser.maxDuration else { return false }
        let timestamp = now()
        if timers.contains(where: {
            $0.label == label && $0.duration == duration && timestamp.timeIntervalSince($0.createdAt) < 2
        }) { return false }

        let timer = ActiveTimer(
            id: UUID(),
            label: label,
            name: name,
            duration: duration,
            endDate: timestamp.addingTimeInterval(duration),
            createdAt: timestamp,
            firedAt: nil,
            fullScreen: fullScreen
        )
        timers.insert(timer, at: 0)
        scheduleFire(timer, announce: announce)
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

    /// `.timer cancel [all]`: stop every running countdown and any pomodoro session.
    func cancelAll() {
        pomodoroTask?.cancel()
        pomodoroTask = nil
        clearPomodoroSession()
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


    /// `.pomodoro 25/5/4` — work/break lengths in minutes and cycles.
    func startPomodoro(work: TimeInterval, rest: TimeInterval, cycles: Int) {
        let session = PomodoroSession(
            cycle: 1,
            cycles: cycles,
            isWork: true,
            phaseStartedAt: now(),
            workDuration: work,
            breakDuration: rest
        )
        beginPomodoro(session)
    }

    /// Starts a fresh session or resumes a persisted one. Reconciles the
    /// current phase against the loaded timers: a chip still counting down is
    /// left alone, one that already elapsed while closed advances the session
    /// to the next phase instead of replaying a finished one.
    private func beginPomodoro(_ session: PomodoroSession) {
        pomodoroTask?.cancel()
        var running = session
        if let existing = timers.first(where: { $0.label == session.label }) {
            if existing.firedAt != nil, let next = nextPhase(after: running) {
                running = next
                beginPhase(next)
            }
        } else {
            beginPhase(running)
        }
        persistPomodoroSession(running)
        pomodoroTask = Task { [weak self] in
            await self?.runPomodoro(running)
        }
    }

    /// Starts the phase timer for `session`. Silent: the runner owns the
    /// transition sound, so the phase timers do not double-chime.
    private func beginPhase(_ session: PomodoroSession) {
        let duration = session.isWork ? session.workDuration : session.breakDuration
        start(duration: duration, label: session.label, announce: false)
    }

    /// The phase that follows `session`, or nil when the work of the last
    /// cycle finished (no trailing break).
    private func nextPhase(after session: PomodoroSession) -> PomodoroSession? {
        var next = session
        if next.isWork {
            guard next.cycle < next.cycles else { return nil }
            next.isWork = false
        } else {
            next.isWork = true
            next.cycle += 1
        }
        next.phaseStartedAt = now()
        return next
    }

    private func runPomodoro(_ initial: PomodoroSession) async {
        var session = initial
        while !Task.isCancelled {
            let duration = session.isWork ? session.workDuration : session.breakDuration
            let elapsed = max(0, self.now().timeIntervalSince(session.phaseStartedAt))
            try? await Task.sleep(for: .seconds(max(0.05, duration - elapsed)))
            guard !Task.isCancelled else { return }
            NSSound(named: "Glass")?.play()
            guard let next = nextPhase(after: session) else {
                clearPomodoroSession()
                return
            }
            session = next
            beginPhase(next)
            persistPomodoroSession(session)
        }
    }


    private func resumePomodoroIfNeeded() {
        guard let session = loadPomodoroSession() else { return }
        beginPomodoro(session)
    }

    private func loadPomodoroSession() -> PomodoroSession? {
        guard let data = try? Data(contentsOf: pomodoroFileURL),
              let stored = try? JSONDecoder().decode(PomodoroSession.self, from: data)
        else { return nil }
        return stored
    }

    private func persistPomodoroSession(_ session: PomodoroSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: pomodoroFileURL, options: .atomic)
    }

    private func clearPomodoroSession() {
        try? FileManager.default.removeItem(at: pomodoroFileURL)
    }


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
        if announce, timer.fullScreen {
            TimerOverlayWindow.shared.show(timer: timers[index])
        }
        persist()
    }


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
