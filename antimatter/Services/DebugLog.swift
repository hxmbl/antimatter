import Foundation

/// A lightweight in-app event log backing the `.debug` pane. Each event is
/// echoed to the system log (so it also shows up in unified logging), and the
/// most recent lines are kept in memory so the pane can print recent activity
/// without any external logging tooling.
@MainActor
final class DebugLog {
    static let shared = DebugLog()

    private(set) var lines: [String] = []
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func log(_ message: String) {
        let stamped = "[\(formatter.string(from: Date()))] \(message)"
        NSLog("Antimatter %@", message)
        Self.shared.record(stamped)
    }

    private func record(_ line: String) {
        lines.append(line)
        if lines.count > 100 {
            lines.removeFirst(lines.count - 100)
        }
    }
}