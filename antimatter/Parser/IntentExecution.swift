import Foundation

/// The glue layer between raw typing and executed intents, extracted from
/// `PaneEditor.Coordinator` so the reentrancy-sensitive decisions can be
/// tested without an `NSTextView`. This type only decides; the coordinator
/// keeps the side effects (undo coalescing, text insertion, timer starts).
///
/// Subtlety that lives here:
/// * **Caret line range** — the line under a collapsed caret, newline
///   stripped, nil for selections spanning characters.
/// * **Return-key dispatch** — timers first, then aggregates (`sum`),
///   paste streaming, dates, units, variable definitions, calculations.
/// * **Reactive results** — committed `expr = number` lines whose number no
///   longer matches the freshly evaluated expression are collected as
///   commits so editing a definition updates its dependents.
/// * **Deferred commit** — the staleness guards that keep an async answer
///   from landing in text the user has already moved past.
nonisolated enum IntentExecution {

    // MARK: Caret line range

    /// The line under a collapsed caret with its trailing newline removed,
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
        /// Hand the line to the calculation rewriter.
        case rewriteCalculation
        /// Replace the caret line wholesale (dates, units, definitions).
        case rewriteLine(String)
        /// Recompute the aggregate over the whole buffer onto this line.
        case insertAggregate(AggregateKind)
        /// Begin streaming clipboard contents into the note.
        case startPasteStream
        /// Leave the line alone; the newline simply lands.
        case nothing
    }

    /// What pressing return on `line` should do, given the surrounding
    /// `buffer` (needed for aggregates and definitions). A trailing `=`
    /// defers to the async commit path instead — asking for an answer must
    /// never double as starting a timer (`timer 5 =` stays a question).
    static func action(forLine line: String, in buffer: String? = nil) -> LineAction {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("=") else { return .nothing }

        if let timer = IntentParser.parseTimer(trimmed) {
            return .startTimer(timer)
        }
        if let kind = AggregateKind(keyword: trimmed) {
            return buffer != nil ? .insertAggregate(kind) : .nothing
        }
        if trimmed.lowercased() == IntentParser.commandPrefix + "paste" {
            return .startPasteStream
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
        return calculationCommit(in: line, at: NSRange(location: 0, length: (line as NSString).length)) != nil
            ? .rewriteCalculation
            : .nothing
    }

    /// A definition gaining its value on return: `price = 4 * 12` becomes
    /// `price = 4 * 12 = 48`. The right-hand side must evaluate against the
    /// note's variables, and bare-number definitions (`a = 5`) stay put —
    /// writing `a = 5 = 5` helps nobody.
    private static func assignmentCommit(line: String, buffer: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (name, rhs) = VariableTable.splitDefinition(trimmed),
              let value = ExpressionEvaluator.evaluate(rhs, variables: VariableTable.scan(buffer)),
              IntentParser.format(value) != rhs
        else { return nil }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        return indent + trimmed + " = " + IntentParser.format(value)
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
