import Foundation

/// Generates a live diagnostics + recent-event report for `.debug`.
enum DebugReport {
    static func generate() -> String {
        var out: [String] = []
        out.append("Antimatter — debug")
        out.append("")
        let fileURL = StorageLocation.directory(named: "notes").appendingPathComponent("notes.json")
        out.append("notes:   \(fileURL.path) (\(NoteStore.shared.notes.count))")
        let active = NoteStore.shared.activeNote
        if !active.title.isEmpty {
            out.append("active:  \(active.title)")
        } else {
            out.append("active:  <empty note>")
        }
        if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            out.append("         \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        out.append("font:    \(PaneStyle.fontSize)pt")
        let timers = TimerCenter.shared.timers
        if timers.isEmpty {
            out.append("timers:  none")
        } else {
            out.append("timers:  \(timers.count)")
            for timer in timers {
                out.append("         • \(timer.label.isEmpty ? "unlabelled" : timer.label) · \(TimerCenter.format(timer.duration))")
            }
        }
        let reminders = ReminderCenter.shared.reminders
        if reminders.isEmpty {
            out.append("remind:  none")
        } else {
            out.append("remind:  \(reminders.count)")
            for reminder in reminders {
                out.append("         • \(reminder.message) · \(ReminderCenter.format(reminder.date.timeIntervalSinceNow))")
            }
        }
        out.append("paste:   \(PasteStream.shared.isStreaming ? "streaming" : "idle")")
        out.append("")
        let logLines = DebugLog.shared.lines
        out.append("log (\(logLines.count)):")
        if logLines.isEmpty {
            out.append("         (nothing captured yet)")
        } else {
            out.append(contentsOf: logLines.map { "         \($0)" })
        }
        return out.joined(separator: "\n")
    }
}
