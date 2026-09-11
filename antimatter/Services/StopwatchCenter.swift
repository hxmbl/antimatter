import Combine
import Foundation

struct ActiveStopwatch: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    let startedAt: Date
    let createdAt: Date
    /// Set when the user stops the watch; the frozen elapsed time stays on
    /// the chip. nil means the watch is still running.
    var stoppedAt: Date?
}

/// Runs `.stopwatch` counters. A stopwatch counts up, unlike a timer, and
/// it never "ends" — so there is no sound and no system notification; the
/// chip in the corner is the whole surface. Elapsed time is derived from
/// `startedAt`, so a stopwatch keeps counting across relaunches (close the
/// app and reopen it later and the same watch is still running), and a
/// stopped one lingers as its final reading until dismissed.
@MainActor
final class StopwatchCenter: ObservableObject {
    static let shared = StopwatchCenter()

    @Published private(set) var stopwatches: [ActiveStopwatch] = []

    private let fileURL: URL
    private let now: () -> Date

    init(fileURL: URL = StopwatchCenter.defaultFileURL(), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    nonisolated static func defaultFileURL() -> URL {
        StorageLocation.directory(named: "stopwatches").appendingPathComponent("stopwatches.json")
    }

    /// Starts a stopwatch counting from now. Returns false for an accidental
    /// duplicate (pressing return twice on the same line).
    @discardableResult
    func start(label: String) -> Bool {
        let timestamp = now()
        if stopwatches.contains(where: {
            $0.label == label && timestamp.timeIntervalSince($0.createdAt) < 2
        }) { return false }

        let stopwatch = ActiveStopwatch(
            id: UUID(),
            label: label,
            startedAt: timestamp,
            createdAt: timestamp,
            stoppedAt: nil
        )
        stopwatches.insert(stopwatch, at: 0)
        persist()
        DebugLog.log("stopwatch started — \(label.isEmpty ? "unlabelled" : label)")
        return true
    }

    /// Freezes a running stopwatch so its reading stops (and stays shown).
    func stop(_ id: UUID) {
        guard let index = stopwatches.firstIndex(where: { $0.id == id }),
              stopwatches[index].stoppedAt == nil
        else { return }
        stopwatches[index].stoppedAt = now()
        persist()
        DebugLog.log("stopwatch stopped — \(stopwatches[index].label.isEmpty ? "unlabelled" : stopwatches[index].label)")
    }

    func dismiss(_ id: UUID) {
        stopwatches.removeAll { $0.id == id }
        persist()
    }

    /// `.stopwatch cancel [all]` — discard every stopwatch, running or not.
    func cancelAll() {
        let count = stopwatches.count
        stopwatches.removeAll()
        persist()
        DebugLog.log("stopwatches cancelled — \(count)")
    }

    /// The current elapsed reading, or the frozen final one when stopped.
    func elapsed(_ stopwatch: ActiveStopwatch) -> TimeInterval {
        if let stoppedAt = stopwatch.stoppedAt {
            return stoppedAt.timeIntervalSince(stopwatch.startedAt)
        }
        return now().timeIntervalSince(stopwatch.startedAt)
    }

    /// `0:05`, `1:20:00` — matches the countdown chips.
    nonisolated static func format(_ interval: TimeInterval) -> String {
        TimerCenter.format(interval)
    }

    // MARK: Persistence

    /// Maximum age for a running stopwatch before it is auto-expired on load.
    /// Prevents abandoned stopwatches from counting up indefinitely.
    private static let maxRunningAge: TimeInterval = 24 * 3600

    private func load() {
        // Same recovery rule as the timers: a corrupt or missing primary
        // falls back to the last good generation in stopwatches.json.bak.
        for url in [fileURL, Persistence.backupURL(for: fileURL)] {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode([ActiveStopwatch].self, from: data)
            else { continue }
            let timestamp = now()
            // Stopped chips linger an hour so their final reading can be seen
            // (and dismissed); older ones are dropped. Running ones older than
            // maxRunningAge are auto-stopped at their expiry rather than
            // counting up indefinitely.
            stopwatches = stored.compactMap { stopwatch in
                if let stoppedAt = stopwatch.stoppedAt {
                    return timestamp.timeIntervalSince(stoppedAt) < 60 * 60 ? stopwatch : nil
                }
                guard timestamp.timeIntervalSince(stopwatch.startedAt) < Self.maxRunningAge else {
                    var expired = stopwatch
                    expired.stoppedAt = stopwatch.startedAt.addingTimeInterval(Self.maxRunningAge)
                    return expired
                }
                return stopwatch
            }
            return
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stopwatches) else { return }
        // Backup rotation skips an undecodable primary: after a recovery
        // from stopwatches.json.bak, the corrupt file must not bury the last
        // good generation.
        Persistence.writeData(data, to: fileURL) { primary in
            (try? JSONDecoder().decode([ActiveStopwatch].self, from: primary)) != nil
        }
    }
}