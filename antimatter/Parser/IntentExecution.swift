import Foundation

/// The glue layer between raw typing and executed intents, extracted from
/// `PaneEditor.Coordinator` so the reentrancy-sensitive decisions can be
/// tested without an `NSTextView`. This type only decides; the coordinator
/// keeps the side effects (undo coalescing, text insertion, timer starts).
///
/// Three pieces of subtlety live here:
/// * **Caret line range** — the line under a collapsed caret, newline
///   stripped, nil for selections spanning characters.
/// * **Calc rewrite** — turning `384 * 27` into `384 * 27 = 10368`,
///   preserving indentation and skipping dates, prose, and identity results.
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

    // MARK: Calculation rewrite

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

    // MARK: Return-key decision

    enum LineAction: Equatable {
        case startTimer(IntentParser.Timer)
        /// Hand the line to the calculation rewriter.
        case rewriteCalculation
        /// Leave the line alone; the newline simply lands.
        case nothing
    }

    /// What pressing return on `line` should do. A trailing `=` defers to
    /// the async commit path instead — asking for an answer must never
    /// double as starting a timer (`timer 5 =` stays a question).
    static func action(forLine line: String) -> LineAction {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("=") else { return .nothing }
        if let timer = IntentParser.parseTimer(trimmed) {
            return .startTimer(timer)
        }
        return calculationCommit(in: line, at: NSRange(location: 0, length: (line as NSString).length)) != nil
            ? .rewriteCalculation
            : .nothing
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
