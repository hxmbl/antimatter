import Foundation

// MARK: - Intent execution

/// Glue layer between raw typing and executed intents.
nonisolated enum IntentExecution {

    // MARK: Caret line

    /// The line under the caret with its trailing newline removed.
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

    // MARK: Commit model

    /// A committed answer: replace `range` in the buffer with `replacement`.
    struct Commit: Equatable {
        let range: NSRange
        let replacement: String
    }

    // MARK: Commits on return

    /// Everything needed to rewrite a segment into `expression = result`,
    /// or nil when nothing should happen.
    static func calculationCommit(in text: String, at contentRange: NSRange?, buffer: String? = nil) -> Commit? {
        guard let contentRange, contentRange.length > 0,
              NSMaxRange(contentRange) <= (text as NSString).length
        else { return nil }
        let ns = text as NSString
        let line = ns.substring(with: contentRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        let calculation = IntentParser.pendingCalculation(trimmedLine, buffer: buffer)
            ?? IntentParser.parseCalculation(trimmedLine, buffer: buffer)
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

        private static let aliases: [(command: String, kind: AggregateKind)] = [
            ("sum", .sum), ("total", .sum),
            ("avg", .avg), ("average", .avg),
            ("count", .count),
        ]

        /// Whole-line match: the entire trimmed token must be the command
        /// (`.sum`, `.total`, `.avg`, `.average`, `.count`) with no arguments.
        init?(keyword: String) {
            guard keyword.hasPrefix(IntentParser.commandPrefix) else { return nil }
            let stem = String(keyword.dropFirst(IntentParser.commandPrefix.count)).lowercased()
            guard !stem.contains(" ") else { return nil }
            for (command, kind) in Self.aliases where command == stem {
                self = kind
                return
            }
            return nil
        }

        /// Split `.sum 10 20 30` into its kind, the command name typed,
        /// and the unparsed argument string (may be empty for bare `.sum`).
        ///
        /// Only the *command word* is matched case-insensitively. Lower-casing the
        /// whole line — which this used to do — also lower-cased the arguments, so
        /// a `where` predicate's string literals were rewritten: `.sum where
        /// upper(it) == "A"` compared against `"a"`, never matched, and then the
        /// "unevaluable predicate ⇒ keep everything" rule hid the failure by
        /// keeping all the numbers.
        static func split(_ line: String) -> (kind: AggregateKind, command: String, args: String)? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(IntentParser.commandPrefix) else { return nil }
            let afterPrefix = trimmed.dropFirst(IntentParser.commandPrefix.count)
            let head = afterPrefix.prefix { !$0.isWhitespace }
            let stem = head.lowercased()
            for (command, kind) in Self.aliases {
                guard stem == command || afterPrefix.hasPrefix("\(command) ") else { continue }
                let args = afterPrefix
                    .dropFirst(command.count)
                    .trimmingCharacters(in: .whitespaces)
                return (kind, IntentParser.commandPrefix + command, args)
            }
            return nil
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

    /// Numbers an aggregate command should operate on. Explicit arguments win
    /// — `.sum 10 20 30`, a range (`.sum 1..10`), a list literal (`.sum [1,2,3]`)
    /// or a whole expression (`.sum 2 * 3`) — otherwise the note's numbers.
    /// A trailing `where <predicate>` / `if <predicate>` filters the numbers,
    /// binding `it` to each one: `.sum where it > 10`.
    static func aggregateNumbers(forLine line: String, in text: String) -> [Double] {
        guard let parts = AggregateKind.split(line) else {
            return Aggregates.numbers(in: text)
        }
        let (payload, predicate) = splitAggregateFilter(parts.args)
        let candidates: [Double]
        if payload.isEmpty {
            candidates = Aggregates.numbers(in: text)
        } else {
            // Resolve the argument expression against the note's own variables,
            // so `.sum :items` / `.avg :rate` see what the note defines. The
            // buffer is passed too, so `$()` inside the arguments still works.
            candidates = aggregateArgumentNumbers(
                payload,
                variables: VariableTable.scan(text),
                buffer: text
            )
        }
        guard let predicate, !predicate.isEmpty else { return candidates }
        return filter(candidates, by: predicate, in: text)
    }

    /// Splits `.sum ... where <expr>` (or `if <expr>`) after the first
    /// whitespace-delimited keyword. Returns the numbers part and predicate.
    private static func splitAggregateFilter(_ args: String) -> (payload: String, predicate: String?) {
        let words = args.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() where word == "where" || word == "if" {
            let payload = words[..<index].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let predicate = words[(index + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (payload, predicate.isEmpty ? nil : predicate)
        }
        return (args.trimmingCharacters(in: .whitespaces), nil)
    }

    /// Explicit aggregate arguments: a single Spark expression that evaluates
    /// (`.sum 1..10`, `.sum :items`, `.sum [1,2,3]`, `.sum 2 * 3` → 6), falling
    /// back to an unparsed number list (`.sum 10 20 30`).
    ///
    /// `variables` is the note's table — without it a variable reference can
    /// never resolve, the whole attempt fails, and the `listLiterals` fallback
    /// yields nothing for a bare name. So `.sum :items` reported "No numbers
    /// after `.sum` to sum" for a note where `:items` was perfectly well defined.
    private static func aggregateArgumentNumbers(
        _ args: String,
        variables: [String: SparkValue],
        buffer: String?
    ) -> [Double] {
        if let value = ExpressionEvaluator.evaluateValue(args, variables: variables, buffer: buffer) {
            let numbers = ExpressionEvaluator.numbers(from: value)
            if !numbers.isEmpty {
                return numbers
            }
        }
        return ExpressionEvaluator.listLiterals(args)
    }

    /// Keeps the numbers a `where` / `if` predicate accepts. `it` is bound to
    /// each number, so `where it > 10` filters; a predicate ignoring `it` acts
    /// as a constant gate. A predicate that can't be evaluated is ignored and
    /// the numbers are kept, matching Spark's quiet-failure posture.
    private static func filter(_ numbers: [Double], by predicate: String, in text: String) -> [Double] {
        var variables = VariableTable.scan(text)
        var accepts: [Bool] = []
        for number in numbers {
            variables["it"] = .number(number)
            guard let result = ExpressionEvaluator.evaluateValue(predicate, variables: variables)?.boolean else { return numbers }
            accepts.append(result)
        }
        return zip(numbers, accepts).compactMap { $1 ? $0 : nil }
    }

    /// Evaluates a numeric command inside `$()` without committing anything.
    static func commandDryRun(_ line: String, buffer: String?) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = AggregateKind.split(trimmed) {
            return parts.kind.value(of: aggregateNumbers(forLine: trimmed, in: buffer ?? ""))
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "time" {
            return TimeIntent.numeric()
        }
        return nil
    }

    /// Rewrites a `.sum` / `.avg` / `.count` line into `.sum = 102`,
    /// aggregating explicit arguments when given, otherwise the numbers
    /// found across the whole note.
    static func aggregateCommit(
        _ kind: AggregateKind, keyword: String, in text: String, at contentRange: NSRange?
    ) -> Commit? {
        guard let contentRange, contentRange.length > 0,
              NSMaxRange(contentRange) <= (text as NSString).length,
              let value = kind.value(of: aggregateNumbers(forLine: keyword, in: text))
        else { return nil }
        let ns = text as NSString
        let line = ns.substring(with: contentRange)
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return Commit(range: contentRange, replacement: indent + trimmedKeyword + " = " + IntentParser.format(value))
    }

    /// Committed answer lines whose stored result drifted, and aggregate
    /// lines whose note changed. Editing a definition lands here.
    static func staleResultCommits(in text: String) -> [Commit] {
        let ns = text as NSString
        var variables = VariableTable.scan(text)
        // Bare literal assignments provide context for dependent expressions,
        // while computed assignments remain ordinary note text.
        for fullRange in VariableTable.lineRanges(ns) {
            let trimmed = ns.substring(with: fullRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (name, expression) = VariableTable.arithmeticDefinition(trimmed),
                  !trimmed.hasPrefix(":"),
                  let value = Double(expression.trimmingCharacters(in: .whitespaces))
            else { continue }
            variables[name.lowercased()] = .number(value)
        }
        var commits: [Commit] = []
        for fullRange in VariableTable.lineRanges(ns) {
            guard let lineRange = strippedLineRange(fullRange, in: ns) else { continue }
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.components(separatedBy: " = ")
            guard parts.count >= 2,
                  let storedToken = parts.last,
                  Self.looksLikeCommittedAnswer(storedToken)
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

            // Any Spark value, not just a number. `.flatMap(\.number)` sat here too, so
            // even with the gate above widened, a boolean or string answer was
            // extracted as `nil` and skipped.
            let value: SparkValue?
            if let kind = AggregateKind.split(expression) {
                value = kind.kind.value(of: aggregateNumbers(forLine: expression, in: text))
                    .map(SparkValue.number)
            } else {
                value = ExpressionEvaluator.evaluateValue(expression, variables: variables)
            }
            guard let value, value.isFinite,
                  IntentParser.format(value) != storedText
            else { continue }

            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let replacement = indent
                + parts.dropLast().joined(separator: " = ")
                + " = " + IntentParser.format(value)
            commits.append(Commit(range: lineRange, replacement: replacement))
        }
        return commits
    }

    /// Whether the right-hand side of `expr = …` looks like a committed Spark
    /// answer rather than prose.
    ///
    /// This used to be `Double(token) != nil`, which silently excluded two of
    /// the four value types the language produces: a committed `2 > 1 = true` or
    /// `"a" + "b" = "ab"` was never eligible for a refresh, so every boolean and
    /// string result in a note went stale forever while the numeric ones healed
    /// themselves the moment you typed.
    nonisolated static func looksLikeCommittedAnswer(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if Double(trimmed) != nil { return true }
        if trimmed == "true" || trimmed == "false" { return true }
        return trimmed.count >= 2 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
    }

    // MARK: Time-based reevaluation

    /// Detects whether the document contains any `.time` expressions that would benefit from live updates.
    static func containsTimeExpressions(_ text: String) -> Bool {
        let ns = text as NSString
        for fullRange in VariableTable.lineRanges(ns) {
            guard let range = strippedLineRange(fullRange, in: ns) else { continue }
            let trimmed = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let command = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            if command?.lowercased() == IntentParser.commandPrefix + "time" {
                return true
            }
        }
        return false
    }

    /// Committed `.time` lines whose stored timestamp has drifted (minute boundary crossed).
    static func staleTimeCommits(in text: String, now: Date = Date()) -> [Commit] {
        let ns = text as NSString
        var commits: [Commit] = []
        let newTimestamp = TimeIntent.format(now)
        for fullRange in VariableTable.lineRanges(ns) {
            guard let lineRange = strippedLineRange(fullRange, in: ns) else { continue }
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains(" = ") else { continue }

            let parts = trimmed.components(separatedBy: " = ")
            guard parts.count >= 2 else { continue }
            let command = parts[0].trimmingCharacters(in: .whitespaces)
            guard command.lowercased() == IntentParser.commandPrefix + "time" else { continue }

            let storedTimestamp = parts[1].trimmingCharacters(in: .whitespaces)
            guard newTimestamp != storedTimestamp else { continue }

            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            commits.append(Commit(
                range: lineRange,
                replacement: indent + command + " = " + newTimestamp))
        }
        return commits
    }

    /// Line range with a trailing newline stripped, or nil when empty.
    private static func strippedLineRange(_ fullRange: NSRange, in ns: NSString) -> NSRange? {
        guard fullRange.length > 0 else { return nil }
        var range = fullRange
        if ns.character(at: NSMaxRange(range) - 1) == unichar(10) {
            range.length -= 1
        }
        return range.length > 0 ? range : nil
    }


    // MARK: Variables report

    /// The reference block `.vars` expands into: every `:name = expression`
    /// definition and the value it evaluates to, resolved in document order
    /// (forward references included). Definitions that can't resolve stay text
    /// and are explained, rather than vanishing silently.
    static func variablesReport(in text: String) -> String {
        let table = VariableTable.scan(text)
        let unresolved = VariableTable.unresolvedDefinitions(in: text)
        let ns = text as NSString
        var rows: [(line: String, value: String)] = []
        for fullRange in VariableTable.lineRanges(ns) {
            let trimmed = ns.substring(with: fullRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (name, _) = VariableTable.splitDefinition(trimmed),
                  let value = table[name]
            else { continue }
            rows.append((trimmed, IntentParser.format(value)))
        }
        var out: [String] = []
        out.append("\(IntentParser.languageName) variables — \(rows.count) \(rows.count == 1 ? "definition" : "definitions")")
        if rows.isEmpty {
            out.append("")
            out.append("  Define one with a `:name = expression` line.")
            out.append("  `:name` then resolves in later expressions, or does a")
            out.append("  live value swap anywhere via $(:name).")
        } else {
            out.append("")
            let width = rows.map(\.line.count).max() ?? 0
            for row in rows {
                out.append("  \(row.line.padding(toLength: width + 2, withPad: " ", startingAt: 0))= \(row.value)")
            }
            out.append("")
            out.append("Use :name in any later expression, or $() to swap it into running text.")
        }
        if !unresolved.isEmpty {
            let circular = Set(VariableTable.circularDependencies(in: text))
            out.append("")
            out.append("\(unresolved.count) \(unresolved.count == 1 ? "definition stays" : "definitions stay") as text:")
            for definition in unresolved {
                let deps = ExpressionEvaluator.dependencies(in: definition.rhs)
                let reason: String
                if deps.contains(definition.name) {
                    reason = "self-reference"
                } else if circular.contains(definition.name) {
                    reason = "circular"
                } else if let missing = deps.first(where: { table[$0] == nil }) {
                    reason = "':\(missing)' not defined"
                } else {
                    reason = "can't be computed"
                }
                out.append("  :\(definition.name) = \(definition.rhs)   ·   \(reason)")
            }
        }
        return out.joined(separator: "\n")
    }


    // MARK: Action model

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
        /// Clear the active note's text (`.clear`).
        case clearNote
        /// Bring up the note switcher menu (`.switch`).
        case showNoteSwitcher
        /// Delete the active note (`.delete`).
        case deleteNote
        /// Export the whole note somewhere local (`.export notes` / `.export obsidian`).
        case export(ExportDestination)
        /// Expand `.help` into the command reference block.
        case showHelp
        /// Open the app's settings window (`.settings`).
        case showSettings
        /// Expand `.debug` into a diagnostics + log reference block.
        case showDebug
        /// Expand `.stats` into the usage report.
        case showStats
        /// Expand `.vars` into the note's variable definitions.
        case showVariables
        /// Quit Antimatter cleanly (`.exit` / `.quit`).
        case quit
        /// Minimize the pane out of the way (`.hide`).
        case hide
        /// Undo the last edit (`.undo`).
        case undo
        /// Redo the last undone edit (`.redo`).
        case redo
        /// Expand `.timer list` into the running-timers report.
        case listTimers
        /// Expand `.reminder list` into the pending-reminders report.
        case listReminders
        /// Expand `.stopwatch list` into the stopwatches report.
        case listStopwatches
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

    // MARK: Return-key dispatch

    /// What pressing return on `line` should do, given the surrounding
    /// `buffer` (needed for aggregates and definitions). A trailing `=`
    /// defers to the async commit path instead — asking for an answer must
    /// never double as starting a timer (`.timer 5 =` stays a question).
    static func action(forLine line: String, in buffer: String? = nil) -> LineAction {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("=") else { return .nothing }
        // A leading backslash marks the line as literal text: no command, no rewrite.
        guard !IntentParser.isEscaped(trimmed) else { return .nothing }

        if let pomodoro = IntentParser.parsePomodoro(trimmed) {
            return .startPomodoro(workDuration: pomodoro.workDuration, breakDuration: pomodoro.breakDuration, cycles: pomodoro.cycles)
        }
        if trimmed.lowercased().hasPrefix(IntentParser.commandPrefix + "timer") {
            if IntentParser.isTimerCancel(trimmed) {
                return .cancelAllTimers
            }
            if trimmed.lowercased() == IntentParser.commandPrefix + "timer list" {
                return .listTimers
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
            if trimmed.lowercased() == IntentParser.commandPrefix + "stopwatch list" {
                return .listStopwatches
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
            if trimmed.lowercased() == IntentParser.commandPrefix + "reminder list"
                || trimmed.lowercased() == IntentParser.commandPrefix + "remind list"
            {
                return .listReminders
            }
            if let reminder = ReminderIntent.parse(trimmed) {
                return .startReminder(reminder)
            }
            return .hint(".remind needs a time and a message — e.g. `.remind in 10 mins stand up`")
        }
        if let parts = AggregateKind.split(trimmed) {
            guard let buffer else { return .nothing }
            let numbers = aggregateNumbers(forLine: trimmed, in: buffer)
            guard !numbers.isEmpty else {
                let whereTo = parts.args.isEmpty
                    ? "in the note to \(parts.kind.name)"
                    : "after `\(parts.command)` to \(parts.kind.name)"
                return .hint("No numbers \(whereTo)")
            }
            return .insertAggregate(parts.kind)
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "time" {
            return .rewriteLine(TimeIntent.commit(trimmed))
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "export" {
            return .hint("Export where? — `.export notes`, `.export obsidian`, `.export json`, or `.export csv`")
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
        if trimmed.lowercased() == IntentParser.commandPrefix + "clear" {
            return .clearNote
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "switch" {
            return .showNoteSwitcher
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "delete" {
            return .deleteNote
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
        if trimmed.lowercased() == IntentParser.commandPrefix + "stats" {
            return .showStats
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "vars" {
            return .showVariables
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "exit"
            || trimmed.lowercased() == IntentParser.commandPrefix + "quit"
        {
            return .quit
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "hide" {
            return .hide
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "undo" {
            return .undo
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "redo" {
            return .redo
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "find" {
            return .showFindPanel
        }
        if trimmed.lowercased().hasPrefix(IntentParser.commandPrefix + "replace ") {
            let rest = String(trimmed.dropFirst((IntentParser.commandPrefix + "replace ").count))
            if let arrow = replaceArrowRange(in: rest) {
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
        if calculationCommit(in: line, at: NSRange(location: 0, length: (line as NSString).length), buffer: buffer ?? trimmed) != nil {
            return .rewriteCalculation
        }
        // A definition that can't resolve should say why instead of quietly
        // doing nothing.
        if let definition = VariableTable.splitDefinition(trimmed) {
            if let diagnostic = definitionDiagnostic(for: definition, in: buffer ?? trimmed) {
                return .hint(diagnostic)
            }
            return .nothing
        }
        // A math-shaped line that fails to evaluate gets feedback rather than
        // silence.
        if ExpressionEvaluator.looksArithmetic(trimmed),
           let message = ExpressionEvaluator.error(
               in: trimmed,
               variables: VariableTable.scan(buffer ?? ""),
               buffer: buffer ?? trimmed)
        {
            return .hint(message)
        }
        // A line that still starts with a dot after every parser said no is a
        // command attempt gone quiet; the pane should say so rather than
        // pretend it typed a word.
        if trimmed.hasPrefix(IntentParser.commandPrefix) {
            return .hint("Not a command — try `.help`")
        }
        return .nothing
    }

    /// Why a `:name = expression` definition stays text, or nil when it's fine.
    /// Surfaces the previously-silent variable failures as a return-key hint.
    static func definitionDiagnostic(for definition: (name: String, expression: String), in buffer: String) -> String? {
        let name = definition.name
        let rhs = definition.expression
        let table = VariableTable.scan(buffer)
        let deps = ExpressionEvaluator.dependencies(in: rhs)
        if deps.contains(name) {
            return ":\(name) can't be defined from itself"
        }
        if VariableTable.circularDependencies(in: buffer).contains(name) {
            return ":\(name) is caught in a circular definition"
        }
        for dep in deps where table[dep] == nil {
            return "':\(dep)' isn't defined yet"
        }
        // Dependencies met but the line still can't resolve: the expression
        // itself is bad (division by zero, a malformed `if`, an unknown
        // function), so say so instead of silently staying text.
        guard ExpressionEvaluator.evaluateValue(rhs, variables: table, buffer: buffer) != nil else {
            return ExpressionEvaluator.error(in: rhs, variables: table, buffer: buffer)
                ?? ":\(name) can't be computed"
        }
        return nil
    }

    /// Preserve established bare `name = expression` behavior. Explicit
    /// `:name = expression` definitions stay literal.
    private static func assignmentCommit(line: String, buffer: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix(":"),
              let (_, rhs) = VariableTable.splitDefinition(trimmed),
              let value = ExpressionEvaluator.evaluate(rhs, variables: VariableTable.scan(buffer).compactMapValues(\.number)),
              IntentParser.format(value) != rhs
        else { return nil }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        return indent + trimmed + " = " + IntentParser.format(value)
    }

    // MARK: List continuation

    /// What pressing return should do inside a list item, Notion-style:
    /// reopen the item with the same marker, or end the list when the item
    /// is empty (just the marker). nil when the line is not a list item.
    enum ListContinuation: Equatable {
        /// Reopen the list with this marker (includes a trailing space).
        case `continue`(marker: String)
        /// The item is empty; pressing return removes the marker.
        case endList
    }

    /// Continuation for `- foo` → `- `, `1. a` → `2. `, `- [x] done` →
    /// `- [x] `; `- ` alone ends the list. Numbered markers increment from
    /// the line's leading number (`.`, and only the renderer's own markers —
    /// `-+*` and `1.` — continue). nil for non-list lines.
    static func listContinuation(forLine line: String) -> ListContinuation? {
        var markerIndex = line.startIndex
        while markerIndex < line.endIndex, line[markerIndex] == " " || line[markerIndex] == "\t" {
            markerIndex = line.index(after: markerIndex)
        }
        guard markerIndex < line.endIndex else { return nil }
        let indent = String(line[..<markerIndex])
        let rest = line[markerIndex...]

        var markerText = ""
        guard let first = rest.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            var cursor = rest.index(after: rest.startIndex)
            // `- [ ]`, `- [x]`, `- [X]` (and the * / + twins) repeat their
            // whole box — the item type survives the newline.
            //
            // Layout after the bullet is `cursor` = space, `cursor + 1` = `[`,
            // `cursor + 2` = the box glyph, `cursor + 3` = `]`. The glyph used
            // to be read from `cursor + 1` — the very slot the next line
            // compares against `"["` — so the condition demanded the glyph be
            // simultaneously `[` and one of ` `/`x`/`X` and could never hold.
            // The block was unreachable, and `- [x] milk` continued as a bare
            // `- `, silently dropping the checkbox.
            //
            // Fixing that contradiction would in turn expose a trap the dead
            // code was hiding: the closing `]` was read at
            // `index(cursor, offsetBy: 3, limitedBy: endIndex)`, which *returns*
            // `endIndex` rather than nil, so dereferencing it traps on a line
            // that is just `- [x`. Every lookahead now goes through
            // `IntentParser.safeIndex`, and `cursor` is bounds-checked first
            // because for a bare `-` it already equals `endIndex`.
            var boxed = false
            if cursor < rest.endIndex, rest[cursor] == " ",
               let openBracket = IntentParser.safeIndex(rest, from: cursor, by: 1, inside: rest.endIndex),
               let glyphIndex = IntentParser.safeIndex(rest, from: cursor, by: 2, inside: rest.endIndex),
               let closeBracket = IntentParser.safeIndex(rest, from: cursor, by: 3, inside: rest.endIndex),
               rest[openBracket] == "[",
               rest[closeBracket] == "]" {
                let glyph = rest[glyphIndex]
                if glyph == " " || glyph == "x" || glyph == "X" {
                    markerText = String(first) + " [" + String(glyph) + "]"
                    cursor = rest.index(after: closeBracket)
                    boxed = true
                }
            }
            if !boxed {
                markerText = String(first)
                cursor = rest.index(after: rest.startIndex)
            }
            guard cursor == rest.endIndex || rest[cursor] == " " || rest[cursor] == "\t" else { return nil }
            let content = cursor < rest.endIndex ? rest[rest.index(after: cursor)...] : rest[cursor...]
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .endList
            }
            return .continue(marker: indent + markerText + " ")
        }
        if first.isNumber {
            var digitsEnd = rest.startIndex
            while digitsEnd < rest.endIndex, rest[digitsEnd].isNumber {
                digitsEnd = rest.index(after: digitsEnd)
            }
            guard digitsEnd < rest.endIndex, rest[digitsEnd] == "." else { return nil }
            guard let number = Int(String(rest[rest.startIndex..<digitsEnd])) else { return nil }
            let markerEnd = rest.index(after: digitsEnd)
            guard markerEnd == rest.endIndex || rest[markerEnd] == " " || rest[markerEnd] == "\t" else { return nil }
            let content = markerEnd < rest.endIndex ? rest[rest.index(after: markerEnd)...] : rest[markerEnd...]
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .endList
            }
            return .continue(marker: indent + "\(number + 1). ")
        }
        return nil
    }


    // MARK: Command parsing helpers

    nonisolated /// The arrow that splits a `.replace find → replace` line into its two
    /// halves; `->` is accepted as well as the typographic `→`.
    static func replaceArrowRange(in text: String) -> Range<String.Index>? {
        text.range(of: " → ") ?? text.range(of: " -> ")
    }

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
        case .json: "JSON"
        case .csv: "CSV"
        }
    }


    // MARK: Help reference

    /// The reference block `.help` expands into on return: every dot-command
    /// plus the automatic line replies. Kept in the parser layer so it can be
    /// tested and translated without touching an `NSTextView`. The command
    /// sections are generated from `dotCommands` so a new command can't be
    /// added without appearing here too.
    static var helpText: String {
        let referenceKeys = """
        Reference view keys:
            j/k  lines  ·  h/l  horizontal
            space/f  page ↓  ·  b  page ↑
            Ctrl-d/Ctrl-u  half page  ·
            gg/G  top/bottom  ·
            H/M/L  screen third  ·
            0/$  line ends
            w/b/e  word jumps  ·
            type a number first to repeat ·
            q/Esc  close

        \(IntentParser.languageName) commands — type one and press return:
        """
        let automatic = """
        \(IntentParser.languageName) automatic — press return on a line:
          384 * 27            →  384 * 27 = 10368
          2 > 1               →  2 > 1 = true
          "a" + "b"           →  "a" + "b" = "ab"
          price = 4 * 12      →  price = 4 * 12 = 48
          2026-08-22          →  weekday appended
          days until 2026-09-01  →  countdown appended
          12 kg -> lb         →  12 kg -> lb = 26.46
        """
        let categories: [DotCommandCategory] = [
            .timers, .noteManagement, .math, .utilities, .searchSystem
        ]
        var sections: [String] = []
        for category in categories {
            let commands = dotCommands.filter { $0.category == category }
            let width = (commands.map { $0.name.count }.max() ?? 0) + 3
            var lines = [category.rawValue]
            for command in commands {
                let padded = command.name.padding(toLength: width, withPad: " ", startingAt: 0)
                lines.append("  \(padded)\(command.description)")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return referenceKeys + "\n\n" + sections.joined(separator: "\n\n") + "\n\n" + automatic
    }


    // MARK: Live preview

    /// A short string describing what return would do on `line`, living
    /// alongside the caret so the answer previews before the newline lands.
    /// nil means plain text: return just adds a newline. Mirrors `action`
    /// without its side-effect outcomes (timers, streams) collapsing into
    /// descriptions.
    static func preview(forLine line: String, in buffer: String? = nil) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("="), !IntentParser.isEscaped(trimmed) else { return nil }

        if trimmed.lowercased() == IntentParser.commandPrefix + "timer list" {
            return "⏎ lists running timers"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "stopwatch list" {
            return "⏎ lists stopwatches"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "reminder list"
            || trimmed.lowercased() == IntentParser.commandPrefix + "remind list"
        {
            return "⏎ lists upcoming reminders"
        }
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
        if let parts = AggregateKind.split(trimmed), let buffer {
            guard let value = parts.kind.value(of: aggregateNumbers(forLine: trimmed, in: buffer)) else { return nil }
            return "⏎ \(trimmed) = \(IntentParser.format(value))"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "time" {
            return "⏎ .time = \(TimeIntent.format(Date()))"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "paste" {
            return "⏎ begins paste stream"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "new" {
            return "⏎ creates a new, empty note"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "clear" {
            return "⏎ clears the note"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "switch" {
            return "⏎ switches to another note"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "delete" {
            return "⏎ deletes the note"
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
        if trimmed.lowercased() == IntentParser.commandPrefix + "stats" {
            return "⏎ shows your usage statistics"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "vars" {
            return "⏎ lists this note's variable definitions"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "exit"
            || trimmed.lowercased() == IntentParser.commandPrefix + "quit"
        {
            return "⏎ quits Antimatter"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "hide" {
            return "⏎ hides the pane"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "undo" {
            return "⏎ undoes the last edit"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "redo" {
            return "⏎ redoes the last undone edit"
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "find" {
            return "⏎ opens the find bar"
        }
        if trimmed.lowercased().hasPrefix(IntentParser.commandPrefix + "replace ") {
            let rest = String(trimmed.dropFirst((IntentParser.commandPrefix + "replace ").count))
            if let arrow = replaceArrowRange(in: rest) {
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
        if let commit = calculationCommit(in: line, at: NSRange(location: 0, length: (line as NSString).length), buffer: buffer ?? line) {
            return "⏎ " + commit.replacement.trimmingCharacters(in: .whitespaces)
        }
        if let definition = VariableTable.splitDefinition(trimmed) {
            if let diagnostic = definitionDiagnostic(for: definition, in: buffer ?? trimmed) {
                return "⏎ " + diagnostic
            }
            return nil
        }
        if ExpressionEvaluator.looksArithmetic(trimmed),
           let message = ExpressionEvaluator.error(
               in: trimmed,
               variables: VariableTable.scan(buffer ?? ""),
               buffer: buffer ?? trimmed)
        {
            return "⏎ " + message
        }
        return nil
    }


    // MARK: Completed-answer parsing

    /// The copyable answer embedded in a committed line: the trailing number
    /// of `expr = 48`, `.sum = 46`, or `days until … = 8`, or the weekday of
    /// `2026-08-22 = Saturday`. Plain prose is nil.
    static func answer(fromLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: " = ")
        if let last = parts.last, parts.count >= 2 {
            let token = last.trimmingCharacters(in: .whitespaces)
            if Double(token) != nil { return token }
            if token == "true" || token == "false" { return token }
            if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
                return String(token.dropFirst().dropLast())
            }
        }
        if parts.count == 2,
           IntentParser.looksLikeDate(parts[0]),
           !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }


    enum DotCommandCategory: String, CaseIterable {
        case timers = "Timers & Reminders"
        case noteManagement = "Note Management"
        case math = "Math & Aggregates"
        case utilities = "Utilities"
        case searchSystem = "Search & System"
    }

    struct DotCommand: Equatable {
        var name: String
        var description: String
        var snippet: String
        var category: DotCommandCategory

        init(name: String, description: String, snippet: String? = nil, category: DotCommandCategory) {
            self.name = name
            self.description = description
            self.snippet = snippet ?? (name + " ")
            self.category = category
        }
    }

    /// Completion vocabulary for typing after a `.` — teaches the commands
    /// at the moment of use, with no chrome.
    static let dotCommands: [DotCommand] = [
        DotCommand(name: ".new", description: "create a new, empty note", category: .noteManagement),
        DotCommand(name: ".clear", description: "clear the current note", category: .noteManagement),
        DotCommand(name: ".switch", description: "switch to another note", category: .noteManagement),
        DotCommand(name: ".delete", description: "delete the current note", category: .noteManagement),
        DotCommand(name: ".undo", description: "undo the last edit", category: .noteManagement),
        DotCommand(name: ".redo", description: "redo the last undone edit", category: .noteManagement),
        DotCommand(name: ".timer", description: "start a countdown — .timer <duration> [label]",
                   snippet: ".timer <duration> ", category: .timers),
        DotCommand(name: ".timer cancel all", description: "cancel every running timer",
                   snippet: ".timer cancel all ", category: .timers),
        DotCommand(name: ".timer list", description: "show running timers and leftovers",
                   snippet: ".timer list ", category: .timers),
        DotCommand(name: ".stopwatch", description: "start a stopwatch — .stopwatch [label]",
                   snippet: ".stopwatch ", category: .timers),
        DotCommand(name: ".stopwatch cancel all", description: "cancel every running stopwatch",
                   snippet: ".stopwatch cancel all ", category: .timers),
        DotCommand(name: ".stopwatch list", description: "show stopwatch readings",
                   snippet: ".stopwatch list ", category: .timers),
        DotCommand(name: ".remind", description: "set a natural-language reminder",
                   snippet: ".remind <what> <when> ", category: .timers),
        DotCommand(name: ".reminder", description: "cancel reminders — .reminder cancel all",
                   snippet: ".reminder cancel all ", category: .timers),
        DotCommand(name: ".reminder list", description: "show pending reminders",
                   snippet: ".reminder list ", category: .timers),
        DotCommand(name: ".reminder cancel all", description: "cancel every pending reminder",
                   snippet: ".reminder cancel all ", category: .timers),
        DotCommand(name: ".pomodoro", description: "start a pomodoro cycle",
                   snippet: ".pomodoro 25/5/4 ", category: .timers),
        DotCommand(name: ".paste", description: "stream clipboard into the note", category: .noteManagement),
        DotCommand(name: ".export notes", description: "send the note to Apple Notes", category: .noteManagement),
        DotCommand(name: ".export obsidian", description: "save the note as markdown in a vault", category: .noteManagement),
        DotCommand(name: ".export json", description: "save note + variable values as JSON", category: .noteManagement),
        DotCommand(name: ".export csv", description: "save variable values as a CSV table", category: .noteManagement),
        DotCommand(name: ".sum", description: "sum numbers — .sum [10 20 30]",
                   snippet: ".sum ", category: .math),
        DotCommand(name: ".avg", description: "average numbers — .avg [10 20 30]",
                   snippet: ".avg ", category: .math),
        DotCommand(name: ".total", description: "sum numbers — same as `.sum`", category: .math),
        DotCommand(name: ".average", description: "average numbers — same as `.avg`", category: .math),
        DotCommand(name: ".count", description: "count numbers — .count [10 20 30]",
                   snippet: ".count ", category: .math),
        DotCommand(name: ".time", description: "stamp the current time", category: .utilities),
        DotCommand(name: ".find", description: "open the find bar", category: .searchSystem),
        DotCommand(name: ".replace", description: "global replace (`.replace find → replace`)",
                   snippet: ".replace <find> → <replace> ", category: .searchSystem),
        DotCommand(name: ".settings", description: "open the settings window", category: .searchSystem),
        DotCommand(name: ".debug", description: "show diagnostics and the event log", category: .searchSystem),
        DotCommand(name: ".stats", description: "show your usage statistics", category: .searchSystem),
        DotCommand(name: ".hide", description: "minimize the pane out of the way", category: .searchSystem),
        DotCommand(name: ".vars", description: "list this note's :name = expression definitions", category: .utilities),
        DotCommand(name: ".exit", description: "quit Antimatter", category: .searchSystem),
        DotCommand(name: ".quit", description: "quit Antimatter (same as .exit)", category: .searchSystem),
        DotCommand(name: ".help", description: "show the command reference", category: .searchSystem),
    ]

    // MARK: Command completion

    /// Completion candidates with rich metadata, used by the AutoReact panel.
    /// Matches in priority order: exact prefix on the command name, substring
    /// on the name or description, then fuzzy (subsequence) matching.
    /// Results are sorted by category so the panel renders grouped sections.
    /// Pass `usageCount` from the UI to rank within a category; tests leave it
    /// at zero so ordering stays deterministic.
    static func completionCandidates(
        for prefix: String,
        buffer: String? = nil,
        usageCount: (String) -> Int = { _ in 0 }
    ) -> [DotCommand] {
        // `:name` completions come from the note's variables, so typing `:pi`
        // (or `$(:p`, which hands over a `:`-prefixed token) suggests the
        // live `:price` etc. without leaving the keyboard.
        if prefix.hasPrefix(":") {
            return variableCompletionCandidates(partial: String(prefix.dropFirst()), in: buffer ?? "")
        }
        guard prefix.hasPrefix(IntentParser.commandPrefix) else { return [] }
        let partial = String(prefix.dropFirst(IntentParser.commandPrefix.count)).lowercased()
        let ranked = { categorySort($0, $1, usageCount: usageCount) }
        guard !partial.isEmpty else { return dotCommands.sorted(by: ranked) }

        let prefixMatches = dotCommands.filter { isPrefixMatch($0, partial: partial) }
        if !prefixMatches.isEmpty { return prefixMatches.sorted(by: ranked) }

        let substringMatches = dotCommands.filter {
            $0.name.lowercased().contains(partial) ||
            $0.description.lowercased().contains(partial)
        }
        if !substringMatches.isEmpty { return substringMatches.sorted(by: ranked) }

        return dotCommands.filter {
            fuzzyMatch(partial, against: $0.name.lowercased())
        }.sorted(by: ranked)
    }

    /// `:name` completion candidates from the note's variable table, rendered
    /// as `.math` dot-commands so the panel groups them with the aggregates.
    /// Inert notes (no definitions) offer nothing.
    private static func variableCompletionCandidates(partial: String, in buffer: String) -> [DotCommand] {
        let table = VariableTable.scan(buffer)
        guard !table.isEmpty else { return [] }
        let partial = partial.lowercased()
        return table.keys.sorted().compactMap { name in
            guard partial.isEmpty || name.lowercased().hasPrefix(partial),
                  let value = table[name]
            else { return nil }
            return DotCommand(
                name: ":" + name,
                description: "= " + IntentParser.format(value),
                snippet: ":" + name + " ",
                category: .math
            )
        }
    }

    private static func isPrefixMatch(_ command: DotCommand, partial: String) -> Bool {
        let name = String(command.name.dropFirst(IntentParser.commandPrefix.count)).lowercased()
        guard name.hasPrefix(partial) else { return false }
        guard let space = name.firstIndex(of: " ") else { return true }
        let firstWord = String(name[..<space])
        let hasBareParent = dotCommands.contains {
            String($0.name.dropFirst(IntentParser.commandPrefix.count)).lowercased() == firstWord
        }
        guard hasBareParent else { return true }
        return partial == firstWord || partial.hasPrefix(firstWord + " ")
    }

    /// Display order for the completion panel's grouped sections, and for the
    /// sort that uses it. Built once: this used to be assembled inside the
    /// comparison closure, so every `sort` of the command list allocated and
    /// hashed a fresh dictionary on every single comparison — O(n log n)
    /// allocations on a path that runs on each keystroke.
    private nonisolated static let categoryOrder: [DotCommandCategory: Int] = {
        var order: [DotCommandCategory: Int] = [:]
        for (offset, category) in DotCommandCategory.allCases.enumerated() {
            order[category] = offset
        }
        return order
    }()

    private static func categorySort(
        _ lhs: DotCommand,
        _ rhs: DotCommand,
        usageCount: (String) -> Int
    ) -> Bool {
        if lhs.category != rhs.category {
            return (categoryOrder[lhs.category] ?? .max) < (categoryOrder[rhs.category] ?? .max)
        }
        let lhsUsage = usageCount(lhs.name)
        let rhsUsage = usageCount(rhs.name)
        if lhsUsage != rhsUsage { return lhsUsage > rhsUsage }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func fuzzyMatch(_ pattern: String, against text: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        var textIndex = text.startIndex
        for patternCharacter in pattern {
            guard let next = text[textIndex...].firstIndex(of: patternCharacter) else {
                return false
            }
            textIndex = text.index(after: next)
        }
        return true
    }

    // MARK: Caret token

    /// Character markers as scalars.
    ///
    /// `unichar` takes a *number*. `unichar(".")` therefore falls back to
    /// `LosslessStringConvertible`, cannot parse a non-numeric character, and
    /// returns `nil` — so `ns.character(at: i) == unichar(".")` compares a real
    /// character against `nil` and is silently false for every input. Every
    /// marker comparison goes through these constants instead.
    private static let scalarDot: unichar = 46          // "."
    private static let scalarColon: unichar = 58        // ":"
    private static let scalarDollar: unichar = 36       // "$"
    private static let scalarOpenParen: unichar = 40   // "("
    private static let scalarNewline: unichar = 10      // "\n"

    /// The run of characters before the caret that a completion token can
    /// occupy, stopping at whitespace.
    private static let completionWhitespace: Set<unichar> = [32, 9, 10, 13]

    /// Where the command or variable marker sits inside a bare word ending at
    /// `end`: 0 for a `.`/`:`-led word, 2 for one inside `$(`, nil when the
    /// word starts neither. `$(` on its own is deliberately nil — there is
    /// nothing to complete until the marker arrives.
    static func commandAnchor(in ns: NSString, from start: Int, to end: Int) -> Int? {
        guard start < end else { return nil }
        let first = ns.character(at: start)
        if first == scalarDot || first == scalarColon { return 0 }
        guard start + 2 < end,
              first == scalarDollar,
              ns.character(at: start + 1) == scalarOpenParen
        else { return nil }
        let marker = ns.character(at: start + 2)
        return (marker == scalarDot || marker == scalarColon) ? 2 : nil
    }

    /// The token the completion panel should offer for a caret at `location`,
    /// or nil when there is nothing there to complete.
    ///
    /// A word counts when it starts a command or variable reference — `.t`,
    /// `:pri`, or the same inside `$(.sum` / `$(:price`. A bare `.` or `:` is
    /// one character long and is a token like any other, which is what lets the
    /// panel open on the marker alone.
    ///
    /// A second word extends a command word before it, so `.timer l` completes
    /// `.timer list`. Without that the space ended the token, the lone `l` was
    /// not a command start, and the registry's multi-word entries were
    /// unreachable by typing — reachable only by arrowing or Tab-cycling from
    /// the shortlist, which is the opposite of what the panel is for. The
    /// extension is gated on the preceding word being a real command name, so
    /// ordinary prose (`.timer 5 soup`, `.sum 10`) does not open the panel: the
    /// candidates for such a token come back empty and the panel dismisses.
    static func completionToken(in ns: NSString, at location: Int) -> NSRange? {
        guard location > 0, location <= ns.length else { return nil }

        var start = location
        while start > 0, !completionWhitespace.contains(ns.character(at: start - 1)) {
            start -= 1
        }
        // The caret sits in whitespace: no partial word under it.
        guard start < location else { return nil }

        if let extended = extendedCompletionToken(in: ns, wordStart: start, location: location) {
            return extended
        }
        guard let anchor = commandAnchor(in: ns, from: start, to: location) else { return nil }
        return NSRange(location: start + anchor, length: location - start - anchor)
    }

    /// `.timer l` → the whole `.timer l`, when the word before the space is
    /// itself a dot-command name. nil in every other case, so the plain
    /// single-word path stays the common one.
    private static func extendedCompletionToken(
        in ns: NSString,
        wordStart: Int,
        location: Int
    ) -> NSRange? {
        guard wordStart > 0, completionWhitespace.contains(ns.character(at: wordStart - 1)) else {
            return nil
        }
        var commandEnd = wordStart - 1
        while commandEnd > 0, completionWhitespace.contains(ns.character(at: commandEnd - 1)) {
            commandEnd -= 1
        }
        var commandStart = commandEnd
        while commandStart > 0, !completionWhitespace.contains(ns.character(at: commandStart - 1)) {
            commandStart -= 1
        }
        guard commandStart < commandEnd,
              commandAnchor(in: ns, from: commandStart, to: commandEnd) == 0,
              isCommandWord(ns.substring(with: NSRange(location: commandStart,
                                                       length: commandEnd - commandStart)))
        else { return nil }
        return NSRange(location: commandStart, length: location - commandStart)
    }

    /// True when `word` is a dot-command's leading word, making it a valid
    /// anchor for a second one. That covers both a bare command (`.timer` in
    /// `.timer cancel all`) and a word shared only by multi-word commands
    /// (`.export`, which has no bare form of its own). Both sides drop the
    /// leading dot so a bare command and a shared prefix compare equal.
    private static func isCommandWord(_ word: String) -> Bool {
        let bare = word.hasPrefix(IntentParser.commandPrefix)
            ? String(word.dropFirst(IntentParser.commandPrefix.count))
            : word
        return dotCommands.contains { command in
            let name = String(command.name.dropFirst(IntentParser.commandPrefix.count))
            if name.compare(bare, options: .caseInsensitive) == .orderedSame { return true }
            guard let space = name.firstIndex(of: " ") else { return false }
            return String(name[..<space]).compare(bare, options: .caseInsensitive) == .orderedSame
        }
    }

    /// What the pane actually asks: the caret token, unless the line is escaped.
    /// Composing the two here keeps the escape rule from being applied in one
    /// place and forgotten in another.
    static func completableToken(in ns: NSString, at location: Int) -> NSRange? {
        guard let range = completionToken(in: ns, at: location),
              !isCompletionEscaped(in: ns, at: range.location)
        else { return nil }
        return range
    }

    /// True when the token at `start` sits on an escaped line (`\ .timer`), so
    /// typing it stays literal and never opens the completion panel.
    static func isCompletionEscaped(in ns: NSString, at start: Int) -> Bool {
        var lineStart = start
        while lineStart > 0, ns.character(at: lineStart - 1) != scalarNewline {
            lineStart -= 1
        }
        let prefix = ns.substring(with: NSRange(location: lineStart, length: start - lineStart))
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.hasPrefix("\\")
    }

    /// Completion strings for text typed after a dot, or nil when the caret
    /// token is not a partial dot-command (`.ti`, `.su`). A bare `.` yields
    /// nil here — the AutoReact panel asks for everything via
    /// `completionCandidates(for:)` instead.
    static func completions(
        for prefix: String,
        usageCount: (String) -> Int = { _ in 0 }
    ) -> [String]? {
        guard prefix.dropFirst(IntentParser.commandPrefix.count).count > 0 else { return nil }
        let candidates = completionCandidates(for: prefix, usageCount: usageCount)
        return candidates.isEmpty ? nil : candidates.map(\.snippet)
    }

    /// The first `<placeholder>` inside a snippet and where it sits in the
    /// inserted text, ready to be selected so the user types over it.
    static func placeholderRange(in snippet: String) -> (NSRange, String)? {
        guard let open = snippet.range(of: "<"),
              let close = snippet.range(of: ">", range: open.upperBound..<snippet.endIndex)
        else { return nil }
        let start = snippet.distance(from: snippet.startIndex, to: open.lowerBound)
        let text = String(snippet[open.lowerBound..<close.upperBound])
        return (NSRange(location: start, length: (text as NSString).length), text)
    }


    // MARK: Completion suppression

    /// Keeps the AutoReact panel from springing straight back open the instant a
    /// completion is accepted — that echo reads as a glitch.
    ///
    /// This used to be a bare `Int`: the accepted token's **offset**. An offset
    /// is the wrong key, because it stays put while the text around it changes.
    /// Accept `.stats ` at offset 5, delete back to `.h`, and the token still
    /// starts at 5, so the panel stayed shut — a dead zone that only a caret
    /// move to a different column could revive, which is why the panel
    /// "never appears" for stretches at a time. The flag was also never reset
    /// on a note switch, so the dead offset followed you into the next note.
    ///
    /// Keying on the buffer the accept actually produced gives the lifetime the
    /// code always intended: the echo is suppressed, and the very next edit
    /// clears it.
    struct CompletionSuppression: Equatable {
        /// The note as it stands immediately after the accepted snippet landed.
        let text: String
        /// Where the caret ended up, so a placeholder selection doesn't count as
        /// an edit and end the suppression early.
        let caret: Int

        /// Whether this suppression is still live for `text` at `caret`.
        func applies(to text: String, caret: Int) -> Bool {
            self.text == text && self.caret == caret
        }
    }

    /// Whether the panel must stay closed because it is still looking at the
    /// very buffer state an accept just produced.
    static func isCompletionSuppressed(
        _ suppression: CompletionSuppression?,
        text: String,
        caret: Int
    ) -> Bool {
        suppression?.applies(to: text, caret: caret) ?? false
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
