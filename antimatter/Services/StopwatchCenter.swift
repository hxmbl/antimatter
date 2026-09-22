import Combine
import Foundation

struct ActiveStopwatch: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    let startedAt: Date
    let createdAt: Date
    /// Set when stopped; the frozen elapsed time stays on the chip.
    var stoppedAt: Date?
}

/// Runs `.stopwatch` counters. Counts up, never "ends", no sound.
/// Keeps counting across relaunches via `startedAt`.
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

    /// Starts a stopwatch. Returns false for duplicates.
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

    /// `.stopwatch list` reference block: each stopwatch's live elapsed
    /// reading, marked when it has been stopped.
    var report: String {
        if stopwatches.isEmpty {
            return "No stopwatches running.\nType `.stopwatch` to start one."
        }
        var out = ["Stopwatches (\(stopwatches.count))", ""]
        for stopwatch in stopwatches {
            let label = stopwatch.label.isEmpty ? "Stopwatch" : stopwatch.label
            let state = stopwatch.stoppedAt == nil ? "" : " (stopped)"
            out.append("  \(Self.format(elapsed(stopwatch)))   \(label)\(state)")
        }
        out.append("")
        out.append("`.stopwatch cancel` clears them.")
        return out.joined(separator: "\n")
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


    /// Maximum age before a running stopwatch is auto-expired on load.
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
        let url = fileURL
        if StorageLocation.isIsolatedRun {
            // Tests reload immediately after a mutation; a background write
            // would race ahead of the read and read stale data back.
            let validate: (Data) -> Bool = { primary in
                (try? JSONDecoder().decode([ActiveStopwatch].self, from: primary)) != nil
            }
            Persistence.writeData(data, to: url, isValidPrimary: validate)
        } else {
            let validate: @Sendable (Data) -> Bool = { primary in
                (try? JSONDecoder().decode([ActiveStopwatch].self, from: primary)) != nil
            }
            Task.detached {
                Persistence.writeData(data, to: url, isValidPrimary: validate)
            }
        }
    }
}