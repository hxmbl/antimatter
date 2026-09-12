import AppKit
import Foundation

// MARK: - Command outcome

/// The result of running a command line: whether the intent was honoured,
/// plus a human-readable description.
struct ActionOutcome: Codable, Equatable {
    let ok: Bool
    let message: String
}

// MARK: - Command execution

/// Executes a dot-command from a context with no caret or text view —
/// a deep link, the loopback bridge, or a test.
@MainActor
enum ActionRunner {
    // MARK: Running dot-commands

    /// Runs the trimmed line against the active note's text.
    static func run(_ line: String) -> ActionOutcome {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return outcome(false, "Nothing to do — type a dot-command like `.timer 5`")
        }
        let buffer = NoteStore.shared.activeNote.text

        switch IntentExecution.action(forLine: trimmed, in: buffer) {
        case .startTimer(let timer):
            let started = TimerCenter.shared.start(
                duration: timer.duration, label: timer.label, name: timer.name, fullScreen: timer.fullScreen
            )
            if timer.clamped {
                notice("Timers cap at 30 days — shortened.")
            }
            if !started {
                return outcome(false, "Couldn't start a timer")
            }
            let detail = timer.name ?? timer.label
            let label = detail.isEmpty ? "" : " — \(detail)"
            return outcome(true, "Timer \(naturalDuration(timer.duration))\(label) started")

        case .startPomodoro(let work, let rest, let cycles):
            TimerCenter.shared.startPomodoro(work: work, rest: rest, cycles: cycles)
            return outcome(true, "Pomodoro \(Int(work)) min / \(Int(rest)) min × \(cycles)")

        case .startStopwatch(let label):
            StopwatchCenter.shared.start(label: label)
            return outcome(true, label.isEmpty ? "Stopwatch started" : "Stopwatch started — \(label)")

        case .cancelStopwatches:
            let count = StopwatchCenter.shared.stopwatches.count
            StopwatchCenter.shared.cancelAll()
            return outcome(true, count == 0 ? "No stopwatches to cancel" : "\(count) stopwatch\(count == 1 ? "" : "es") cancelled")

        case .startReminder(let reminder):
            if ReminderCenter.shared.schedule(message: reminder.message, at: reminder.date) {
                return outcome(true, "Reminder in \(ReminderCenter.format(reminder.date.timeIntervalSinceNow)) — \(reminder.message)")
            }
            return outcome(false, "Reminder needs a future time")

        case .cancelAllTimers:
            let count = TimerCenter.shared.timers.count
            TimerCenter.shared.cancelAll()
            return outcome(true, count == 0 ? "No running timers to cancel" : (count == 1 ? "Timer cancelled" : "\(count) timers cancelled"))

        case .cancelAllReminders:
            let count = ReminderCenter.shared.reminders.count
            ReminderCenter.shared.cancelAll()
            return outcome(true, count == 0 ? "No pending reminders to cancel" : (count == 1 ? "Reminder cancelled" : "\(count) reminders cancelled"))

        case .startPasteStream:
            PasteStream.shared.startStreaming()
            return outcome(true, "Paste stream on — copy into the pane")

        case .newNote:
            let note = NoteStore.shared.create()
            let title = note.text.isEmpty ? "" : " — \(note.title)"
            return outcome(true, "New note\(title)")

        case .export(let destination):
            do {
                let result = try ExportCenter.export(destination, text: NoteStore.shared.activeNote.text)
                return outcome(true, result)
            } catch {
                let message = error.localizedDescription.isEmpty ? "Export cancelled" : error.localizedDescription
                return outcome(false, message)
            }

        case .showSettings:
            (NSApplication.shared.delegate as? AppDelegate)?.openSettings(nil)
            return outcome(true, "Settings opened")

        case .insertAggregate(let kind):
            guard let value = kind.value(of: Aggregates.numbers(in: buffer)) else {
                return outcome(false, "No numbers in the note to \(kind.name)")
            }
            let result = IntentParser.format(value)
            appendLine("\(trimmed) = \(result)")
            return outcome(true, "\(trimmed) = \(result)")

        case .rewriteCalculation:
            guard let calculation = IntentParser.pendingCalculation(trimmed) ?? IntentParser.parseCalculation(trimmed) else {
                return outcome(false, "Couldn't evaluate \(trimmed)")
            }
            let result = IntentParser.format(calculation.result)
            appendLine("\(calculation.expression) = \(result)")
            return outcome(true, result)

        case .rewriteLine(let replacement):
            let clean = replacement.trimmingCharacters(in: .whitespaces)
            appendLine(clean)
            return outcome(true, clean)

        case .showHelp, .showDebug, .showFindPanel, .replaceAll, .showNoteSwitcher:
            return outcome(false, "This needs the pane — open it and press return on the line")

        case .hint(let message):
            notice(message)
            return outcome(false, message)

        case .nothing:
            return outcome(false, "Nothing to do — type a dot-command like `.timer 5`")
        }
    }

    // MARK: Creating and appending notes

    /// Creates a fresh note carrying `text`.
    static func create(text: String) -> ActionOutcome {
        let note = NoteStore.shared.create(text: text)
        return outcome(true, text.isEmpty ? "New note" : "New note — \(note.title)")
    }

    /// Appends `text` to the active note.
    static func append(text: String) -> ActionOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return outcome(false, "Nothing to append") }
        appendLine(trimmed)
        return outcome(true, "Appended")
    }

    // MARK: Feedback formatting

    /// `45s`-sounding natural duration for feedback messages ("Timer 1 min 30 sec").
    nonisolated static func naturalDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h"
        }
        if minutes > 0 {
            return secs > 0 ? "\(minutes) min \(secs) sec" : "\(minutes) min"
        }
        return "\(secs) sec"
    }

    // MARK: Mutation support

    private static func appendLine(_ text: String) {
        var note = NoteStore.shared.activeNote
        note.text += note.text.isEmpty ? text : "\n" + text
        note.modifiedAt = Date()
        NoteStore.shared.activeNote = note
        NoteStore.shared.flush()
    }

    private static func outcome(_ ok: Bool, _ message: String) -> ActionOutcome {
        ActionOutcome(ok: ok, message: message)
    }

    private static func notice(_ message: String) {
        if !ProcessInfo.processInfo.environment.keys.contains("ANTIMATTER_SILENT_ACTIONS") {
            NoticeCenter.shared.show(message)
        }
    }
}