import Foundation
import Testing
@testable import antimatter

/// Tests for the glue layer extracted out of `PaneEditor.Coordinator`:
/// caret line ranges, calculation rewrites, return-key decisions, and the
/// deferred-commit staleness guards. All pure — no text view required.
struct CaretLineRangeTests {

    private func range(_ text: String, _ location: Int, _ length: Int = 0) -> NSRange? {
        IntentExecution.caretLineRange(in: text, selection: NSRange(location: location, length: length))
    }

    @Test func wholeLineIsReturned() {
        #expect(range("384 * 27", 5) == NSRange(location: 0, length: 8))
    }

    @Test func trailingNewlineIsExcluded() {
        // "first\nsecond\n" — caret inside "second"
        #expect(range("first\nsecond\n", 9) == NSRange(location: 6, length: 6))
        // "…\n" at end-of-line before the newline lands; "# heading" is nine characters
        #expect(range("# heading\nnext line", 3) == NSRange(location: 0, length: 9))
    }

    @Test func lastLineWithoutNewlineStillResolves() {
        let text = "first\nsecond"
        #expect(range(text, text.count - 1) == NSRange(location: 6, length: 6))
    }

    @Test func eachLineMapsToItsOwnRange() {
        let text = "a\nb\nc"
        #expect(range(text, 0) == NSRange(location: 0, length: 1))
        #expect(range(text, 2) == NSRange(location: 2, length: 1))
        #expect(range(text, 4) == NSRange(location: 4, length: 1))
    }

    @Test func emptyFinalLineYieldsZeroLengthRange() {
        #expect(range("done\n", 5) == NSRange(location: 5, length: 0))
        #expect(range("", 0) == NSRange(location: 0, length: 0))
    }

    @Test func spanningSelectionsAndWildLocationsAreRejected() {
        #expect(range("abc", 0, 3) == nil)
        #expect(range("abc", 99) == nil)
    }
}

struct ReturnKeyActionTests {

    private func action(_ line: String) -> IntentExecution.LineAction {
        IntentExecution.action(forLine: line)
    }

    @Test func timersWinOnTheirLines() {
        #expect(action(".timer 5 laundry") == .startTimer(IntentParser.Timer(duration: 300, label: "laundry")))
        #expect(action(".timer 90s") == .startTimer(IntentParser.Timer(duration: 90, label: "")))
        #expect(action(".timer 5 mins") == .startTimer(IntentParser.Timer(duration: 300, label: "")))
        #expect(action(".timer 2 hours tea") == .startTimer(IntentParser.Timer(duration: 7_200, label: "tea")))
    }

    @Test func pureArithmeticRewrites() {
        #expect(action("384 * 27") == .rewriteCalculation)
        #expect(action("(2+3)*4") == .rewriteCalculation)
        #expect(action("   10 / 4  ") == .rewriteCalculation)
    }

    @Test func trailingEqualsDefersInsteadOfActing() {
        // Asking for an answer must never double as starting a timer.
        #expect(action("384 * 27 =") == .nothing)
        #expect(action(".timer 5 =") == .nothing)
        #expect(action("timer 5 =") == .nothing) // a bare word stays inert
        #expect(action("-5 =") == .nothing)
    }

    @Test func ordinaryTextStaysText() {
        for line in ["", "   ", "hello world", "TODO: investigate this",
                     "42", "rent is due"] {
            #expect(action(line) == .nothing, "`\(line)` should do nothing on return")
        }
    }

    @Test func datesAndUnitsBecomeAnswers() {
        let weekday = IntentExecution.action(forLine: "2026-08-22")
        guard case .rewriteLine(let replacement) = weekday else {
            Issue.record("date should rewrite")
            return
        }
        #expect(replacement.contains("·"))
        if case .rewriteLine = IntentExecution.action(forLine: "days until 2026-09-01") {} else {
            Issue.record("days until should rewrite")
        }
        if case .rewriteLine = IntentExecution.action(forLine: "12 kg → lb") {} else {
            Issue.record("unit conversion should rewrite")
        }
    }

    @Test func definitionsGainTheirValueOnReturn() {
        let buffer = "price = 4 * 12"
        if case .rewriteLine(let replacement) = IntentExecution.action(forLine: buffer, in: buffer) {
            #expect(replacement == "price = 4 * 12 = 48")
        } else {
            Issue.record("definition should gain its value")
        }
        // Bare-number definitions stay put — `a = 5 = 5` helps nobody.
        #expect(IntentExecution.action(forLine: "a = 5", in: "a = 5") == .nothing)
    }

    @Test func dotCommandsNeedTheDot() {
        // Without the dot these are ordinary words; with it they command.
        #expect(action("sum") == .nothing)
        #expect(action("paste") == .nothing)
        #expect(action("help") == .nothing)
        #expect(IntentExecution.action(forLine: ".sum") == .nothing) // no buffer → no aggregate
        if case .insertAggregate(.sum) = IntentExecution.action(forLine: ".sum", in: "12\n34\n.sum") {} else {
            Issue.record(".sum with a buffer should aggregate")
        }
        if case .startPasteStream = IntentExecution.action(forLine: ".paste", in: "") {} else {
            Issue.record(".paste should start streaming")
        }
    }

    @Test func helpExpandsIntoTheCommandReference() {
        if case .showHelp = IntentExecution.action(forLine: ".help", in: "") {} else {
            Issue.record(".help should show the reference block")
        }
        #expect(IntentExecution.helpText.contains(".timer"))
        #expect(IntentExecution.helpText.contains(".sum"))
        #expect(IntentExecution.helpText.contains(".paste"))
        #expect(IntentExecution.helpText.contains(".help"))
        #expect(IntentExecution.helpText.contains("days until"))
    }

    @Test func settingsAndDebugAreCommands() {
        if case .showSettings = IntentExecution.action(forLine: ".settings", in: "") {} else {
            Issue.record(".settings should open the settings window")
        }
        if case .showDebug = IntentExecution.action(forLine: ".debug", in: "") {} else {
            Issue.record(".debug should show the diagnostics reference")
        }
        #expect(IntentExecution.preview(forLine: ".settings") == "⏎ opens the settings window")
        #expect(IntentExecution.preview(forLine: ".debug") == "⏎ shows diagnostics and the event log")
        #expect(IntentExecution.helpText.contains(".settings"))
        #expect(IntentExecution.helpText.contains(".debug"))
        #expect(IntentExecution.completions(for: ".se")?.contains(".settings ") == true)
        #expect(IntentExecution.completions(for: ".de")?.contains(".debug ") == true)
        // Without the dot they are ordinary prose lines.
        #expect(IntentExecution.action(forLine: "settings", in: "") == .nothing)
        #expect(IntentExecution.action(forLine: "debug", in: "") == .nothing)
    }

    @Test func quietFailuresNowSaySomething() {
        // Unknown dot-commands, a duration-less timer, and an empty
        // aggregate each raise a hint instead of dying silently.
        if case .hint(let message) = IntentExecution.action(forLine: ".frobnicate", in: "") {
            #expect(message.contains(".help"))
        } else {
            Issue.record("unknown dot-command should hint")
        }
        if case .hint(let message) = IntentExecution.action(forLine: ".timer", in: "") {
            #expect(message.contains("duration"))
        } else {
            Issue.record(".timer without a duration should hint")
        }
        if case .hint(let message) = IntentExecution.action(forLine: ".sum", in: "no numbers here") {
            #expect(message.contains("No numbers"))
        } else {
            Issue.record("empty aggregate should hint")
        }
        // Real commands are never reflagged as unknown.
        #expect(IntentExecution.action(forLine: ".help", in: "") != .hint("Not a command — try `.help`"))
    }
}

struct LivePreviewTests {
    @Test func arithmeticPreviewsItsAnswer() {
        #expect(IntentExecution.preview(forLine: "384 * 27") == "⏎ 384 * 27 = 10368")
        #expect(IntentExecution.preview(forLine: "10 / 4") == "⏎ 10 / 4 = 2.5")
    }

    @Test func commandsPreviewTheirOutcome() {
        #expect(IntentExecution.preview(forLine: ".help") == "⏎ opens the reference (press q to close)")
        #expect(IntentExecution.preview(forLine: ".paste") == "⏎ begins paste stream")
        if case .startTimer = IntentExecution.action(forLine: ".timer 90s") {
            #expect(IntentExecution.preview(forLine: ".timer 90s") == "⏎ starts a timer")
        } else {
            Issue.record(".timer should preview")
        }
    }

    @Test func aggregatesPreviewOnlyWithNumbers() {
        #expect(IntentExecution.preview(forLine: ".sum", in: "12\n34\n.sum") == "⏎ .sum = 46")
        #expect(IntentExecution.preview(forLine: ".sum", in: "just words") == nil)
    }

    @Test func proseHasNoPreview() {
        for line in ["", "hello world", "TODO: investigate this", "42", "2026-08-22 ="] {
            #expect(IntentExecution.preview(forLine: line) == nil, "`\(line)` should have no preview")
        }
    }

    @Test func answerExtractsThePayload() {
        #expect(IntentExecution.answer(fromLine: "384 * 27 = 10368") == "10368")
        #expect(IntentExecution.answer(fromLine: ".sum = 46") == "46")
        #expect(IntentExecution.answer(fromLine: "days until 2026-09-01 = 8") == "8")
        #expect(IntentExecution.answer(fromLine: "2026-08-22 · Saturday") == "Saturday")
        #expect(IntentExecution.answer(fromLine: "hello world") == nil)
        #expect(IntentExecution.answer(fromLine: "12 kg -> lb") == nil) // not committed yet
        #expect(IntentExecution.answer(fromLine: "price = 4 * 12 = 48") == "48")
    }
}

struct CancelCommandTests {

    @Test func timerCancelDispatches() {
        #expect(IntentExecution.action(forLine: ".timer cancel") == .cancelAllTimers)
        #expect(IntentExecution.action(forLine: ".timer cancel all") == .cancelAllTimers)
        #expect(IntentExecution.preview(forLine: ".timer cancel") == "⏎ cancels all running timers")
    }

    @Test func reminderCancelDispatches() {
        #expect(IntentExecution.action(forLine: ".reminder cancel") == .cancelAllReminders)
        #expect(IntentExecution.action(forLine: ".reminder cancel all") == .cancelAllReminders)
        #expect(IntentExecution.preview(forLine: ".reminder cancel") == "⏎ cancels all reminders")
    }

    @Test func cancelNeverCollidesWithARealCommand() {
        #expect(IntentExecution.action(forLine: ".timer 5") != .cancelAllTimers)
        #expect(IntentExecution.action(forLine: ".remind in 10 mins call mom") != .cancelAllReminders)
    }
}

struct CommandCompletionTests {

    private func completions(_ prefix: String) -> [String]? {
        IntentExecution.completions(for: prefix)
    }

    @Test func partialDotCommandsMatch() {
        #expect(completions(".ti") == [".timer "])
        #expect(completions(".su")?.contains(".sum ") == true)
        #expect(completions(".h")?.contains(".help ") == true)
    }

    @Test func nonCommandsAndEmptyPrefixesDoNotMatch() {
        #expect(completions(".") == nil)
        #expect(completions("time") == nil)
        #expect(completions("hello") == nil)
    }
}

struct CalculationCommitTests {

    private func commit(_ text: String, _ location: Int = 0, _ length: Int? = nil) -> IntentExecution.Commit? {
        let nsLength = (text as NSString).length
        let range = NSRange(location: location, length: length ?? nsLength)
        return IntentExecution.calculationCommit(in: text, at: range)
    }

    @Test func answerAppendsWithSpacing() {
        #expect(commit("384 * 27")?.replacement == "384 * 27 = 10368")
        #expect(commit("10 / 4")?.replacement == "10 / 4 = 2.5")
        #expect(commit("2^10")?.replacement == "2^10 = 1024")
    }

    @Test func indentationSurvivesTheRewrite() {
        #expect(commit("  10 / 4")?.replacement == "  10 / 4 = 2.5")
        #expect(commit("\t2^10")?.replacement == "\t2^10 = 1024")
    }

    @Test func typedEqualsFormReplacesTheQuestionMarkToo() {
        let result = commit("384 * 27 =")
        #expect(result?.replacement == "384 * 27 = 10368")
        #expect(result?.range.length == 10)  // includes the `=`
    }

    @Test func rewriteTargetsOnlyItsOwnSegment() throws {
        let buffer = "todo\n384 * 27\ntimer"
        let result = try #require(commit(buffer, 5, 8))
        #expect(result.range == NSRange(location: 5, length: 8))
        let after = (buffer as NSString).replacingCharacters(in: result.range, with: result.replacement)
        #expect(after == "todo\n384 * 27 = 10368\ntimer")
    }

    @Test func datesProseAndIdentitiesStayUntouched() {
        for line in ["2026-08-22", "12-31", "hello world", "42", "-5 =", "1 / 0", "(2+3"] {
            #expect(commit(line) == nil, "`\(line)` should not be rewritten")
        }
    }

    @Test func emptyAndOutOfBoundsRangesDoNothing() {
        #expect(IntentExecution.calculationCommit(in: "384 * 27", at: nil) == nil)
        #expect(IntentExecution.calculationCommit(in: "384 * 27", at: NSRange(location: 0, length: 0)) == nil)
        #expect(IntentExecution.calculationCommit(in: "abc", at: NSRange(location: 1, length: 99)) == nil)
    }

    @Test func composedWithCaretLineRangeItRewritesTheBuffer() throws {
        let before = "notes\n\n384 * 27"
        let lineRange = try #require(IntentExecution.caretLineRange(
            in: before, selection: NSRange(location: before.count, length: 0)))
        let result = try #require(IntentExecution.calculationCommit(in: before, at: lineRange))
        let after = (before as NSString).replacingCharacters(in: result.range, with: result.replacement)
        #expect(after == "notes\n\n384 * 27 = 10368")
    }
}

struct DeferredCommitGuardTests {

    private func stale(view: String, bound: String, focus: Bool) -> Bool {
        IntentExecution.isDeferredCommitStale(viewText: view, boundText: bound, viewHasFocus: focus)
    }

    @Test func freshUnmovedTextCommits() {
        #expect(!stale(view: "384 * 27 =", bound: "384 * 27 =", focus: true))
    }

    @Test func editedElsewhereMeansStale() {
        // The user kept typing while the async commit was in flight.
        #expect(stale(view: "384 * 27 = and more", bound: "384 * 27 =", focus: true))
    }

    @Test func lostFocusMeansStale() {
        #expect(stale(view: "384 * 27 =", bound: "384 * 27 =", focus: false))
    }
}
