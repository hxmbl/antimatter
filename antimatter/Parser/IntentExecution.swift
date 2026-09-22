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
        static func split(_ line: String) -> (kind: AggregateKind, command: String, args: String)? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(IntentParser.commandPrefix) else { return nil }
            let stem = String(trimmed.dropFirst(IntentParser.commandPrefix.count)).lowercased()
            for (command, kind) in Self.aliases {
                guard stem == command || stem.hasPrefix(command + " ") else { continue }
                let args = String(stem.dropFirst(command.count))
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
        guard let (_, _, args) = AggregateKind.split(line) else {
            return Aggregates.numbers(in: text)
        }
        let (payload, predicate) = splitAggregateFilter(args)
        let candidates: [Double]
        if payload.isEmpty {
            candidates = Aggregates.numbers(in: text)
        } else {
            candidates = aggregateArgumentNumbers(payload, in: text)
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
    private static func aggregateArgumentNumbers(_ args: String, in text: String) -> [Double] {
        if let value = ExpressionEvaluator.evaluateValue(args, variables: [:]) {
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
            if let kind = AggregateKind.split(expression) {
                // Argument- and filter-bearing aggregates recompute reactively
                // too: `.sum 1..10`, `.sum :items`, `.sum where it > 10`.
                value = kind.kind.value(of: aggregateNumbers(forLine: expression, in: text))
            } else {
                value = ExpressionEvaluator.evaluateValue(expression, variables: variables)
                    .flatMap(\.number)
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
            var boxed = false
            if let next = rest.index(cursor, offsetBy: 3, limitedBy: rest.endIndex) {
                let inner = rest[rest.index(after: cursor)]
                if rest[cursor] == " ",
                   rest[rest.index(after: cursor)] == "[",
                   inner == " " || inner == "x" || inner == "X",
                   rest[next] == "]" {
                    markerText = String(first) + " [" + String(inner) + "]"
                    cursor = rest.index(after: next)
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

    private static func categorySort(
        _ lhs: DotCommand,
        _ rhs: DotCommand,
        usageCount: (String) -> Int
    ) -> Bool {
        let categoryOrder = Dictionary(uniqueKeysWithValues:
            DotCommandCategory.allCases.enumerated().map { ($0.element, $0.offset) })
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


    // MARK: Deferred commit guard

    /// Guard for the did-change-deferred commit. The answer may land several
    /// runloop turns after typing, so it must be dropped when the buffer has
    /// moved on (a reentrant edit won the race) or the pane lost first
    /// responder (the user already went elsewhere).
    static func isDeferredCommitStale(viewText: String, boundText: String, viewHasFocus: Bool) -> Bool {
        viewText != boundText || !viewHasFocus
    }
}
