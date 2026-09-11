import AppKit
import Foundation

/// Routes `antimatter://` deep links into the app. The URL scheme is
/// registered in Info.plist; macOS delivers every open to
/// `AppDelegate.application(_:open:)`, which funnels them here.
///
/// Supported forms:
///   antimatter://                         — reveal the pane
///   antimatter://note?text=hello          — create a note with text
///   antimatter://append?text=more         — append to the active note
///   antimatter://command?line=.timer 5    — run a dot-command line
///   antimatter://command?line=384 * 27    — evaluate a line
enum DeepLinkRouter {
    @MainActor
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "antimatter" else { return }

        switch url.host?.lowercased() {
        case "note":
            let text = value("text", from: url) ?? ""
            NoteStore.shared.create(text: text)

        case "append":
            guard let text = value("text", from: url), !text.isEmpty else { return }
            append(text)

        case "command":
            guard let line = value("line", from: url), !line.isEmpty else { return }
            execute(line)

        default:
            // Bare `antimatter://` and unknown hosts just bring the pane up.
            break
        }
    }

    @MainActor
    private static func append(_ text: String) {
        var note = NoteStore.shared.activeNote
        let separator = note.text.isEmpty ? "" : "\n"
        note.text += separator + text
        note.modifiedAt = Date()
        NoteStore.shared.activeNote = note
        NoteStore.shared.flush()
    }

    @MainActor
    private static func execute(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let buffer = NoteStore.shared.activeNote.text

        switch IntentExecution.action(forLine: trimmed, in: buffer) {
        case .startTimer(let timer):
            TimerCenter.shared.start(
                duration: timer.duration, label: timer.label, name: timer.name, fullScreen: timer.fullScreen
            )
            if let active = TimerCenter.shared.timers.last {
                NoticeCenter.shared.show("Timer \(Int(timer.duration / 60)) min — \(active.name ?? timer.label) started")
            }
        case .startPomodoro(let work, let rest, let cycles):
            TimerCenter.shared.startPomodoro(work: work, rest: rest, cycles: cycles)
            NoticeCenter.shared.show("Pomodoro \(Int(work))'/\(Int(rest))' × \(cycles) started")
        case .startStopwatch(let label):
            StopwatchCenter.shared.start(label: label)
            NoticeCenter.shared.show("Stopwatch started")
        case .cancelStopwatches:
            StopwatchCenter.shared.cancelAll()
            NoticeCenter.shared.show("Stopwatches cancelled")
        case .startReminder(let reminder):
            if ReminderCenter.shared.schedule(message: reminder.message, at: reminder.date) {
                NoticeCenter.shared.show("Reminder in \(ReminderCenter.format(reminder.date.timeIntervalSinceNow)) — \(reminder.message)")
            } else {
                NoticeCenter.shared.show("Reminder needs a future time")
            }
        case .cancelAllTimers:
            TimerCenter.shared.cancelAll()
            NoticeCenter.shared.show("Timers cancelled")
        case .cancelAllReminders:
            ReminderCenter.shared.cancelAll()
            NoticeCenter.shared.show("Reminders cancelled")
        case .startPasteStream:
            PasteStream.shared.startStreaming()
        case .newNote:
            NoteStore.shared.create()
        case .export(let destination):
            do {
                let outcome = try ExportCenter.export(destination, text: NoteStore.shared.activeNote.text)
                NoticeCenter.shared.show(outcome)
            } catch {
                NoticeCenter.shared.show(error.localizedDescription.isEmpty ? "Export cancelled." : error.localizedDescription)
            }
        case .showSettings:
            (NSApplication.shared.delegate as? AppDelegate)?.openSettings(nil)
        case .hint(let message), .rewriteLine(let message):
            NoticeCenter.shared.show(message)
        case .nothing, .rewriteCalculation, .insertAggregate, .showHelp, .showDebug, .showFindPanel, .replaceAll:
            break
        }
    }

    private static func value(_ key: String, from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == key }?.value
    }
}