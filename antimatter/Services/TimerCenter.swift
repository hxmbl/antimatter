import Combine
import Foundation
import AppKit

struct ActiveTimer: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    let duration: TimeInterval
    let endDate: Date
    let createdAt: Date
    var firedAt: Date?
}

/// Runs scratchpad timers. `timer 25 soup` schedules a countdown here; the
/// center owns the running list, plays a sound when one elapses, and
/// persists everything so relaunches restore unfinished timers (ones that
/// elapsed while the app was closed come back already marked done, silently).
///
/// Main-actor isolated: the fire tasks mutate `timers` and `fireTasks` after
/// their sleep, and those collections are also read by the countdown chips —
/// without isolation a fire landing mid-dismiss would be a data race.
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
        load()
        for timer in timers {
            scheduleFire(timer, announce: false)
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Antimatter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("timers.json")
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
        return true
    }

    func dismiss(_ id: UUID) {
        timers.removeAll { $0.id == id }
        fireTasks[id]?.cancel()
        fireTasks[id] = nil
        persist()
    }

    // MARK: Firing

    private func scheduleFire(_ timer: ActiveTimer, announce: Bool) {
        guard timer.firedAt == nil else { return }
        let delay = timer.endDate.timeIntervalSince(now())
        guard delay > 0 else {
            expire(timer, announce: announce)
            return
        }
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

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([ActiveTimer].self, from: data)
        else { return }
        let timestamp = now()
        // Finished chips linger an hour after firing so they can be seen
        // (and dismissed); older ones are dropped.
        timers = stored.filter { timer in
            guard let fired = timer.firedAt else { return true }
            return timestamp.timeIntervalSince(fired) < 60 * 60
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(timers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
