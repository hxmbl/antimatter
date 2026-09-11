import Foundation

/// The glue layer between raw typing and executed intents, extracted from
/// `PaneEditor.Coordinator` so the reentrancy-sensitive decisions can be
/// tested without an `NSTextView`. This type only decides; the coordinator
/// keeps the side effects (undo coalescing, text insertion, timer starts).
///
/// Subtlety that lives here:
/// * **Caret line range** — the line under the caret, newline
///   stripped, nil for selections spanning characters.
/// * **Return-key dispatch** — timers first, then dot-commands (`.sum`),
///   paste streaming, dates, units, variable definitions, calculations.
/// * **Reactive results** — committed `expr = number` lines whose number no
///   longer matches the freshly evaluated expression are collected as
///   commits so editing a definition updates its dependents.
/// * **Deferred commit** — the staleness guards that keep an async answer
///   from landing in text the user has already moved past.
nonisolated enum IntentExecution {

    // MARK: Caret line range

    /// The line under the caret with its trailing newline removed,
    /// or nil when the selection spans characters or sits outside the text.
    /// An empty final line yields a zero-length range; callers decide
    /// whether that is worth acting on.
    static func caretLineRange(in text: String, selection: NSRange) -> NSRange? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        guard selection.location <= ns.length else { return nil }
        var range = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == unichar(10) {
            range.length -= 1
        }
        return range
    }

    // MARK: Commits

    /// A committed answer: replace `range` in the buffer with `replacement`.
    struct Commit: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// Everything needed to rewrite the segment at `contentRange` into
    /// `expression = result`, or nil when nothing should happen: nil or
    /// out-of-bounds ranges, prose, date-shaped notes, identity results.
    /// Handles both commit forms — a typed trailing `=` and whole-line
    /// arithmetic on return. Leading indentation is preserved.
    static func calculationCommit(in text: String, at contentRange: NSRange?) -> Commit? {
        guard let contentRange, contentRange.length > 0,
              NSMaxRange(contentRange) <= (text as NSString).length
        else { return nil }
        let ns = text as NSString
        let line = ns.substring(with: contentRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        let calculation = IntentParser.pendingCalculation(trimmedLine)
            ?? IntentParser.parseCalculation(trimmedLine)
        guard let calculation else { return nil }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let replacement = indent + calculation.expression + " = " + IntentParser.format(calculation.result)
        return Commit(range: contentRange, replacement: replacement)
    }

    // MARK: Aggregates

    nonisolated enum AggregateKind: Equatable {
        case sum
        case avg
        case count

        /// Dot-commands only: `.sum`, `.total`, `.avg`, `.average`, `.count`.
        init?(keyword: String) {
            guard keyword.hasPrefix(IntentParser.commandPrefix) else { return nil }
            switch String(keyword.dropFirst(IntentParser.commandPrefix.count)).lowercased() {
            case "sum", "total": self = .sum
            case "avg", "average": self = .avg
            case "count": self = .count
            default: return nil
            }
        }

        /// The aggregate over the note's numbers, or nil with no data —
        /// an empty note leaves the line alone rather than writing `= nan`.
        func value(of numbers: [Double]) -> Double? {
            guard !numbers.isEmpty else { return nil }
            switch self {
            case .sum: return numbers.reduce(0, +)
            case .avg: return numbers.reduce(0, +) / Double(numbers.count)
            case .count: return Double(numbers.count)
            }
        }

        var name: String {
            switch self {
            case .sum: "sum"
            case .avg: "average"
            case .count: "count"
            }
        }
    }

    /// Rewrites a `.sum` / `.avg` / `.count` line into `.sum = 102`,
    /// aggregating the arithmetic numbers found across the whole note.
    static func aggregateCommit(
        _ kind: AggregateKind, keyword: String, in text: String, at contentRange: NSRange?
    ) -> Commit? {
        guard let contentRange, contentRange.length > 0,
              NSMaxRange(contentRange) <= (text as NSString).length,
              let value = kind.value(of: Aggregates.numbers(in: text))
        else { return nil }
        let ns = text as NSString
        let line = ns.substring(with: contentRange)
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return Commit(range: contentRange, replacement: indent + trimmedKeyword + " = " + IntentParser.format(value))
    }

    // MARK: Reactive results

    /// Committed answer lines whose stored result drifted: `expr = number`
    /// (or `name = expr = number`) where the expression now evaluates to
    /// something else, and aggregate lines (`.sum = 46`) whose note changed.
    /// Editing a definition lands here, which is what makes dependent lines
    /// recompute live. Prose, dates, units, and anything that does not
    /// evaluate are left untouched.
    ///
    /// Commit ranges exclude the trailing newline: `lineRange(for:)`
    /// includes it, and replacing it would merge this line into the next.
    static func staleResultCommits(in text: String) -> [Commit] {
        let variables = VariableTable.scan(text)
        let ns = text as NSString
        var commits: [Commit] = []
        for fullRange in VariableTable.lineRanges(ns) where fullRange.length > 0 {
            var lineRange = fullRange
            if ns.character(at: NSMaxRange(lineRange) - 1) == unichar(10) {
                lineRange.length -= 1
            }
            guard lineRange.length > 0 else { continue }
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.components(separatedBy: " = ")
            guard parts.count >= 2,
                  let storedToken = parts.last,
                  Double(storedToken.trimmingCharacters(in: .whitespaces)) != nil
            else { continue }
            let storedText = storedToken.trimmingCharacters(in: .whitespaces)

            var expression = parts.dropLast().joined(separator: " = ")
            if let separator = expression.range(of: "=") {
                let name = String(expression[..<separator.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if VariableTable.isIdentifier(name) {
                    expression = String(expression[separator.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }

            let value: Double?
            if let kind = AggregateKind(keyword: expression.trimmingCharacters(in: .whitespaces)) {
                value = kind.value(of: Aggregates.numbers(in: text))
            } else {
                value = ExpressionEvaluator.evaluate(expression, variables: variables)
            }
            guard let value, IntentParser.format(value) != storedText else { continue }

            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let replacement = indent
                + parts.dropLast().joined(separator: " = ")
                + " = " + IntentParser.format(value)
            commits.append(Commit(range: lineRange, replacement: replacement))
        }
        return commits
    }

    // MARK: Return-key decision

    enum LineAction: Equatable {
        case startTimer(IntentParser.Timer)
        /// Start a running stopwatch (`.stopwatch [label]`); counts up.
        case startStopwatch(String)
        /// Cancel every running stopwatch (`.stopwatch cancel [all]`).
        case cancelStopwatches
        /// Schedule a natural-language reminder (`.remind in 10 mins stand up`).
        case startReminder(ReminderIntent.Reminder)
        /// Cancel every running timer (`.timer cancel [all]`).
        case cancelAllTimers
        /// Cancel every pending reminder (`.reminder cancel [all]`).
        case cancelAllReminders
        /// Start a pomodoro cycle (`.pomodoro 25/5/4`).
        case startPomodoro(workDuration: TimeInterval, breakDuration: TimeInterval, cycles: Int)
        /// Hand the line to the calculation rewriter.
        case rewriteCalculation
        /// Replace the caret line wholesale (dates, units, definitions).
        case rewriteLine(String)
        /// Recompute the aggregate over the whole buffer onto this line.
        case insertAggregate(AggregateKind)
        /// Begin streaming clipboard contents into the note.
        case startPasteStream
        /// Create a brand-new empty note and switch to it (`.new`).
        case newNote
        /// Bring up the note switcher menu (`.switch`). Stub: the menu
        /// presentation is not built yet.
        case showNoteSwitcher
        /// Export the whole note somewhere local (`.export notes` / `.export obsidian`).
        case export(ExportDestination)
        /// Expand `.help` into the command reference block.
        case showHelp
        /// Open the app's settings window (`.settings`).
        case showSettings
        /// Expand `.debug` into a diagnostics + log reference block.
        case showDebug
        /// Trigger the text view's native find panel.
        case showFindPanel
        /// Global replace in the current note.
        case replaceAll(find: String, replacement: String)
        /// Say something through a transient notice instead of acting
        /// (unknown dot-command, missing argument, empty aggregate).
        case hint(String)
        /// Leave the line alone; the newline simply lands.
        case nothing
    }

    /// What pressing return on `line` should do, given the surrounding
    /// `buffer` (needed for aggregates and definitions). A trailing `=`
    /// defers to the async commit path instead — asking for an answer must
    /// never double as starting a timer (`.timer 5 =` stays a question).
    static func action(forLine line: String, in buffer: String? = nil) -> LineAction {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("=") else { return .nothing }

        if let pomodoro = IntentParser.parsePomodoro(trimmed) {
            return .startPomodoro(workDuration: pomodoro.workDuration, breakDuration: pomodoro.breakDuration, cycles: pomodoro.cycles)
        }
        if trimmed.lowercased().hasPrefix(IntentParser.commandPrefix + "timer") {
            if IntentParser.isTimerCancel(trimmed) {
                return .cancelAllTimers
            }
            if let timer = IntentParser.parseTimer(trimmed) {
                return .startTimer(timer)
            }
            return .hint(".timer needs a duration — e.g. `.timer 25`")
        }
        if trimmed.lowercased().hasPrefix(IntentParser.commandPrefix + "stopwatch") {
            if IntentParser.isStopwatchCancel(trimmed) {
                return .cancelStopwatches
            }
            if IntentParser.stopwatchLabel(trimmed).lowercased().hasPrefix("cancel") {
                return .hint(".stopwatch cancel takes no further arguments")
            }
            return .startStopwatch(IntentParser.stopwatchLabel(trimmed))
        }
        if trimmed.lowercased().hasPrefix(ReminderIntent.command) {
            if ReminderIntent.isCancelAll(trimmed) {
                return .cancelAllReminders
            }
            if let reminder = ReminderIntent.parse(trimmed) {
                return .startReminder(reminder)
            }
            return .hint(".remind needs a time and a message — e.g. `.remind in 10 mins stand up`")
        }
        if let kind = AggregateKind(keyword: trimmed) {
            guard let buffer else { return .nothing }
            let numbers = Aggregates.numbers(in: buffer)
            return numbers.isEmpty
                ? .hint("No numbers in the note to \(kind.name)")
                : .insertAggregate(kind)
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "export" {
            return .hint("Export where? — `.export notes` or `.export obsidian`")
        }
        if let destination = exportDestination(from: trimmed) {
            return .export(destination)
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "paste" {
            return .startPasteStream
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "new" {
            return .newNote
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "switch" {
            return .showNoteSwitcher
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "help" {
            return .showHelp
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "settings" {
            return .showSettings
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "debug" {
            return .showDebug
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "find" {
            return .showFindPanel
        }
        if trimmed.lowercased().hasPrefix(IntentParser.commandPrefix + "replace ") {
            let rest = String(trimmed.dropFirst((IntentParser.commandPrefix + "replace ").count))
            if let arrow = rest.range(of: " → ") {
                let find = String(rest[..<arrow.lowerBound])
                let replace = String(rest[arrow.upperBound...])
                if !find.isEmpty {
                    return .replaceAll(find: find, replacement: replace)
                }
            }
            return .hint(".replace needs a pattern — `.replace find → replace`")
        }
        if let replacement = DateIntent.commit(line) {
            return .rewriteLine(replacement)
        }
        if let replacement = UnitConverter.commit(line) {
            return .rewriteLine(replacement)
        }
        if let replacement = assignmentCommit(line: line, buffer: buffer ?? line) {
            return .rewriteLine(replacement)
        }
        if calculationCommit(in: line, at: NSRange(location: 0, length: (line as NSString).length)) != nil {
            return .rewriteCalculation
        }
        // A line that still starts with a dot after every parser said no is a
        // command attempt gone quiet; the pane should say so rather than
        // pretend it typed a word.
        if trimmed.hasPrefix(IntentParser.commandPrefix) {
            return .hint("Not a command — try `.help`")
        }
        return .nothing
    }

    /// A definition gaining its value on return: `price = 4 * 12` becomes
    /// `price = 4 * 12 = 48`. The right-hand side must evaluate against the
    /// note's variables, and bare-number definitions (`a = 5`) stay put —
    /// writing `a = 5 = 5` helps nobody.
    private static func assignmentCommit(line: String, buffer: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (_, rhs) = VariableTable.splitDefinition(trimmed),
              let value = ExpressionEvaluator.evaluate(rhs, variables: VariableTable.scan(buffer)),
              IntentParser.format(value) != rhs
        else { return nil }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        return indent + trimmed + " = " + IntentParser.format(value)
    }

    // MARK: Export

    /// Parses a `.export <destination>` line into its destination, or nil.
    static func exportDestination(from line: String) -> ExportDestination? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix(IntentParser.commandPrefix + "export") else { return nil }
        for destination in ExportDestination.allCases {
            if trimmed == IntentParser.commandPrefix + "export " + destination.rawValue.lowercased() {
                return destination
            }
        }
        return nil
    }

    private static func destinationTitle(_ destination: ExportDestination) -> String {
        switch destination {
        case .appleNotes: "Apple Notes"
        case .obsidian: "Obsidian"
        }
    }

    // MARK: Help

    /// The reference block `.help` expands into on return: every dot-command
    /// plus the automatic line replies. Kept in the parser layer so it can be
    /// tested and translated without touching an `NSTextView`.
    static let helpText = """
        Commands — type one and press return:
          .timer 5                5-minute countdown (bare number = minutes; also 90s, 1h 20m, 5 mins)
          .timer 1h 20m stand up  labelled countdown; max 30 days
          .timer cancel [all]     cancel all running timers
          .stopwatch [label]      stopwatch counting up (chip in the corner)
          .stopwatch cancel       cancel running stopwatches
          .pomodoro 25/5/4        work/break in minutes, 4 cycles (max 12)
          .remind in 10 mins …    natural-language reminder ("call mom", "tomorrow at 3pm …")
          .remind tomorrow 3pm …  absolute times work too
          .reminder cancel [all]  cancel all pending reminders
          .paste                  stream clipboard copies into the note until dismissed
          .new                    create a new, empty note (swipe left/right to switch)
          .switch                 switch to another note (menu)
          .export notes           send the note to Apple Notes
          .export obsidian        save the note as a markdown file in your vault
          .sum  .total            sum the numbers in this note
          .avg  .average          average the note's numbers
          .count                  count the note's numbers
          .find                   open the find bar (also ⌘F)
          .replace find → replace global replace in the note
          .settings               open the settings window
          .debug                  show diagnostics and the event log
          .help                   open this reference full-screen (press q to close)

        Reference view keys:  j/k  scroll  ·  space/b  page  ·  g/G  top/bottom  ·  q/Esc  close

        Automatic — press return on a line:
          384 * 27            →  384 * 27 = 10368
          price = 4 * 12      →  price = 4 * 12 = 48
          2026-08-22          →  weekday appended
          days until 2026-09-01  →  countdown appended
          12 kg -> lb         →  12 kg -> lb = 26.46
        """

    // MARK: Live preview

    /// A short string describing what return would do on `line`, living
    /// alongside the caret so the answer previews before the newline lands.
    /// nil means plain text: return just adds a newline. Mirrors `action`
    /// without its side-effect outcomes (timers, streams) collapsing into
    /// descriptions.
    static func preview(forLine line: String, in buffer: String? = nil) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("=") else { return nil }

        if IntentParser.isTimerCancel(trimmed) {
            return "⏎ cancels all running timers"
        }
        if IntentParser.parsePomodoro(trimmed) != nil {
            return "⏎ starts a pomodoro cycle"
        }
        if IntentParser.parseTimer(trimmed) != nil {
            return "⏎ starts a timer"
        }
        if IntentParser.isStopwatchCancel(trimmed) {
            return "⏎ cancels all stopwatches"
        }
        if IntentParser.isStopwatch(trimmed) {
            return "⏎ starts a stopwatch"
        }
        if ReminderIntent.isCancelAll(trimmed) {
            return "⏎ cancels all reminders"
        }
        if trimmed.lowercased().hasPrefix(ReminderIntent.command),
           let reminder = ReminderIntent.parse(trimmed)
        {
            return "⏎ reminder in \(ReminderCenter.format(reminder.date.timeIntervalSinceNow))"
        }
        if let kind = AggregateKind(keyword: trimmed), let buffer {
            guard let value = kind.value(of: Aggregates.numbers(in: buffer)) else { return nil }
            return "⏎ \(trimmed) = \(IntentParser.format(value))"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "paste" {
            return "⏎ begins paste stream"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "new" {
            return "⏎ creates a new, empty note"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "switch" {
            return "⏎ switches to another note"
        }
        if let destination = exportDestination(from: trimmed) {
            return "⏎ exports the note to \(destinationTitle(destination))"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "help" {
            return "⏎ opens the reference (press q to close)"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "settings" {
            return "⏎ opens the settings window"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "debug" {
            return "⏎ shows diagnostics and the event log"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "find" {
            return "⏎ opens the find bar"
        }
        if trimmed.lowercased().hasPrefix(IntentParser.commandPrefix + "replace ") {
            let rest = String(trimmed.dropFirst((IntentParser.commandPrefix + "replace ").count))
            if let arrow = rest.range(of: " → ") {
                let find = String(rest[..<arrow.lowerBound])
                let replace = String(rest[arrow.upperBound...])
                if !find.isEmpty {
                    return "⏎ replace \"\(find)\" → \"\(replace)\""
                }
            }
            return nil
        }
        if let replacement = DateIntent.commit(line) {
            return "⏎ " + replacement.trimmingCharacters(in: .whitespaces)
        }
        if let replacement = UnitConverter.commit(line) {
            return "⏎ " + replacement.trimmingCharacters(in: .whitespaces)
        }
        if let replacement = assignmentCommit(line: line, buffer: buffer ?? line) {
            return "⏎ " + replacement.trimmingCharacters(in: .whitespaces)
        }
        if let commit = calculationCommit(in: line, at: NSRange(location: 0, length: (line as NSString).length)) {
            return "⏎ " + commit.replacement.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: Answer extraction

    /// The copyable answer embedded in a committed line: the trailing number
    /// of `expr = 48`, `.sum = 46`, or `days until … = 8`, or the weekday of
    /// `2026-08-22 = Saturday`. Plain prose is nil.
    static func answer(fromLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: " = ")
        if let last = parts.last, parts.count >= 2, Double(last.trimmingCharacters(in: .whitespaces)) != nil {
            return last.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2,
           IntentParser.looksLikeDate(parts[0]),
           !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: Dot-command autocompletion

    /// Completion vocabulary for typing after a `.` — teaches the commands
    /// at the moment of use, with no chrome.
    static let dotCommands: [(name: String, description: String)] = [
        (".new", "create a new, empty note"),
        (".switch", "switch to another note"),
        (".timer", "start or cancel a countdown"),
        (".stopwatch", "start or cancel a stopwatch"),
        (".remind", "set a natural-language reminder"),
        (".reminder", "cancel reminders (`.reminder cancel all`)"),
        (".pomodoro", "start a pomodoro cycle (`.pomodoro 25/5/4`)"),
        (".paste", "stream clipboard into the note"),
        (".export notes", "send the note to Apple Notes"),
        (".export obsidian", "save the note as markdown in a vault"),
        (".sum", "sum the note's numbers"),
        (".avg", "average the note's numbers"),
        (".count", "count the note's numbers"),
        (".find", "open the find bar"),
        (".replace", "global replace (`.replace find → replace`)"),
        (".settings", "open the settings window"),
        (".debug", "show diagnostics and the event log"),
        (".help", "show the command reference"),
    ]

    /// Completion strings for text typed after a dot, or nil when the caret
    /// token is not a partial dot-command (`.ti`, `.su`).
    static func completions(for prefix: String) -> [String]? {
        guard prefix.hasPrefix(IntentParser.commandPrefix) else { return nil }
        let partial = String(prefix.dropFirst(IntentParser.commandPrefix.count)).lowercased()
        guard !partial.isEmpty else { return nil }
        let matches = dotCommands.filter { $0.name.dropFirst(IntentParser.commandPrefix.count).hasPrefix(partial) }
        return matches.isEmpty ? nil : matches.map { $0.name + " " }
    }

    // MARK: Deferred commit guard

    /// Guard for the did-change-deferred commit. The answer may land several
    /// runloop turns after typing, so it must be dropped when the buffer has
    /// moved on (a reentrant edit won the race) or the pane lost first
    /// responder (the user already went elsewhere).
    static func isDeferredCommitStale(viewText: String, boundText: String, viewHasFocus: Bool) -> Bool {
        viewText != boundText || !viewHasFocus
    }
}
