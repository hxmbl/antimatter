import Foundation
import Testing
@testable import antimatter

/// Tests for the AutoReact command-completion candidates and their
/// snippet scaffolding.
struct AutoReactCompletionTests {

    @Test func nonDotTokensYieldNothing() {
        #expect(IntentExecution.completionCandidates(for: "") == [])
        #expect(IntentExecution.completionCandidates(for: "sty") == [])
        #expect(IntentExecution.completionCandidates(for: ".terminal") == [])
        #expect(IntentExecution.completions(for: "sty") == nil)
    }

    @Test func bareDotListsEverything() {
        let all = IntentExecution.completionCandidates(for: ".")
        #expect(all.count == IntentExecution.dotCommands.count)
        #expect(all.contains { $0.name == ".help" })
        // Tab right after a `.` should offer every command.
        #expect(!all.isEmpty)
    }

    @Test func prefixFilteringIsCaseInsensitive() {
        let upper = IntentExecution.completionCandidates(for: ".STA")
        let lower = IntentExecution.completionCandidates(for: ".sta")
        #expect(upper.map(\.name) == lower.map(\.name))
        #expect(upper.contains { $0.name == ".stats" })
    }

    @Test func partialPrefixStillMatchesMultiWordCommands() {
        let matches = IntentExecution.completionCandidates(for: ".ex")
        #expect(matches.contains { $0.name == ".exit" })
        #expect(matches.contains { $0.name == ".export notes" })
        // The rich candidate keeps the raw name; the insertable string is the snippet.
        #expect(IntentExecution.completions(for: ".e")?.contains(".exit ") == true)
    }

    @Test func snippetsScaffoldArguments() {
        let replace = IntentExecution.completionCandidates(for: ".rep").first
        #expect(replace?.snippet == ".replace <find> → <replace> ")
        #expect(IntentExecution.completionCandidates(for: ".rem").first?.name == ".remind")
        let remind = IntentExecution.completionCandidates(for: ".rem")[0]
        #expect(remind.snippet == ".remind <what> <when> ")
        #expect(IntentExecution.completionCandidates(for: ".pom").first?.snippet == ".pomodoro 25/5/4 ")
    }

    @Test func plainCommandsInsertNamePlusSpace() {
        let stats = IntentExecution.completionCandidates(for: ".st").first { $0.name == ".stats" }
        #expect(stats?.name == ".stats")
        #expect(stats?.snippet == ".stats ")
        #expect(IntentExecution.completions(for: ".st")?.contains(".stats ") == true)
    }

    @Test func placeholderRangeSpotsFirstArgument() {
        let snippet = ".replace <find> → <replace> "
        let (range, text) = IntentExecution.placeholderRange(in: snippet)!
        #expect(text == "<find>")
        #expect(range.location == ".replace ".utf16.count)
        #expect(range.length == "<find>".utf16.count)
        #expect(IntentExecution.placeholderRange(in: ".stats ") == nil)
    }

    @Test func metadataTravelsWithTheCommand() {
        for command in IntentExecution.dotCommands {
            #expect(!command.name.hasPrefix(" "))
            #expect(command.snippet.hasPrefix(command.name))
            #expect(command.snippet.hasSuffix(" "))
            #expect(IntentExecution.completionCandidates(for: command.name).contains { $0.name == command.name })
        }
    }

    // MARK: Registry completeness

    /// Every command the parser acts on must be completable. `.stopwatch
    /// cancel all` was handled by `action(forLine:)` and documented in the
    /// README but absent from the registry, so AutoReact could never offer it.
    @Test func documentedCommandsAreAllCompletable() {
        let completable = Set(IntentExecution.dotCommands.map(\.name))
        for name in [".stopwatch cancel all", ".timer list", ".timer cancel all",
                     ".stopwatch list", ".reminder list", ".reminder cancel all",
                     ".export notes", ".export obsidian", ".export json",
                     ".export csv", ".sum", ".avg", ".total", ".average",
                     ".count", ".time", ".vars", ".help", ".exit", ".quit",
                     ".new", ".clear", ".switch", ".delete", ".undo", ".redo",
                     ".hide", ".find", ".replace", ".paste", ".settings",
                     ".debug", ".stats", ".pomodoro", ".remind", ".reminder"] {
            #expect(completable.contains(name), "\(name) works but is not completable")
        }
    }

    @Test func aggregateAliasesAreCompletable() {
        #expect(IntentExecution.completionCandidates(for: ".tot").map(\.name) == [".total"])
        #expect(IntentExecution.completionCandidates(for: ".average").map(\.name) == [".average"])
        #expect(IntentExecution.completionCandidates(for: ".stopwatch cancel").map(\.name)
                == [".stopwatch cancel all"])
    }
}

/// The scanning rules that decide what the panel completes at the caret. These
/// used to be private to `PaneEditor`, which is why a bare `.` never opened the
/// panel and the multi-word commands could not be typed to.
/// The rule that keeps the panel from springing back open the instant a
/// completion is accepted, and — the part that was actually broken — the rule
/// that lets it come back afterwards.
struct AutoReactCompletionSuppressionTests {

    private func suppressed(_ text: String, caret: Int) -> IntentExecution.CompletionSuppression {
        .init(text: text, caret: caret)
    }

    private func live(_ suppression: IntentExecution.CompletionSuppression?, _ text: String, caret: Int) -> Bool {
        IntentExecution.isCompletionSuppressed(suppression, text: text, caret: caret)
    }

    @Test func nothingIsSuppressedWithoutAnAccept() {
        #expect(!live(nil, ".time", caret: 5))
    }

    /// The immediate echo is what the rule is for: the buffer an accept just
    /// produced must not reopen the panel.
    @Test func theAcceptItselfIsSuppressed() {
        let after = suppressed("hello.stats ", caret: 12)
        #expect(live(after, "hello.stats ", caret: 12))
    }

    /// The regression. Suppression used to be keyed on the accepted token's
    /// *offset*, which does not move when the text around it does — so after
    /// accepting at offset 5, deleting back down to `.h` (still offset 5) left
    /// the panel shut for good. That is the "autoreact never appears" symptom:
    /// the dead zone only lifted if the caret happened to move to a different
    /// column first.
    @Test func deletingBackToTheSameOffsetClearsTheSuppression() {
        let afterAccept = suppressed("hello.stats ", caret: 12)
        // Backspaced to `hello.h` — the token starts at 5 either way.
        #expect(!live(afterAccept, "hello.h", caret: 7))
    }

    /// Same trap with a placeholder selection: the snippet wrote a different
    /// token at the same offset.
    @Test func retypingTheSameOffsetClearsTheSuppression() {
        let afterAccept = suppressed("hello.replace find → replace ", caret: 15)
        #expect(!live(afterAccept, "hello.replace abc → replace ", caret: 18))
    }

    /// The flag was never reset on a note switch, so a dead offset used to
    /// follow you into the next note. Keying on the buffer makes that
    /// impossible: a different note can never match.
    @Test func aDifferentNoteIsNeverSuppressed() {
        let other = suppressed("hello.stats ", caret: 12)
        #expect(!live(other, ".help", caret: 5))
        #expect(!live(other, "something else entirely", caret: 12))
    }

    /// Moving the caret without typing is not an edit, but it does mean the
    /// user is no longer looking at the accepted text.
    @Test func movingTheCaretClearsTheSuppression() {
        let after = suppressed("hello.stats ", caret: 12)
        #expect(!live(after, "hello.stats ", caret: 6))
    }
}

struct AutoReactCompletionTokenTests {

    private func token(_ text: String, at location: Int? = nil) -> NSRange? {
        IntentExecution.completionToken(in: text as NSString, at: location ?? (text as NSString).length)
    }

    private func candidates(_ text: String, at location: Int? = nil) -> [String] {
        guard let range = token(text, at: location) else { return [] }
        let ns = text as NSString
        return IntentExecution.completionCandidates(for: ns.substring(with: range)).map(\.name)
    }

    // MARK: The bare marker (A1)

    /// A bare `.` is a token, so the panel opens on the marker alone. The
    /// README promises "type `.` and the window lists them"; the old
    /// `tokenRange.length > 1` gate meant it needed a second character.
    @Test func aBareDotIsAToken() {
        let range = token(".")
        #expect(range == NSRange(location: 0, length: 1))
        #expect(candidates(".").count == IntentExecution.dotCommands.count)
    }

    @Test func aBareColonIsAToken() {
        #expect(token(":") == NSRange(location: 0, length: 1))
    }

    /// A bare `:` in a note with no definitions offers nothing, so the panel
    /// has no rows and must not open on it.
    @Test func bareColonWithoutVariablesYieldsNoCandidates() {
        #expect(candidates(":").isEmpty)
    }

    @Test func caretInWhitespaceHasNoToken() {
        #expect(token("") == nil)
        #expect(token(" ") == nil)
        #expect(token(".sum ") == nil)
        #expect(token(".sum ", at: 5) == nil)
        #expect(token("hello ", at: 6) == nil)
    }

    // MARK: Single-word commands

    @Test func partialCommandsAreTokens() {
        #expect(token(".ti") == NSRange(location: 0, length: 3))
        #expect(candidates(".ti").contains(".time"))
    }

    @Test func proseIsNotAToken() {
        #expect(token("remember to fix the relay") == nil)
        #expect(token("hello world") == nil)
    }

    @Test func aTokenIsBoundedByWhitespace() {
        // Mid-line, after ordinary prose: the word still completes.
        #expect(token("buy milk .ti") == NSRange(location: 9, length: 3))
    }

    // MARK: Interpolation (A2)

    /// `$(.sum` hands the panel the `:`/`.`-led token, not the `$(`.
    @Test func interpolationAnchorsInsideTheParens() {
        let text = "$(.sum"
        let ns = text as NSString
        #expect(IntentExecution.completionToken(in: ns, at: ns.length) == NSRange(location: 2, length: 4))
        #expect(IntentExecution.commandAnchor(in: ns, from: 0, to: ns.length) == 2)
    }

    @Test func variableInterpolationAnchorsToo() {
        let text = "$(:pri"
        let ns = text as NSString
        #expect(IntentExecution.completionToken(in: ns, at: ns.length) == NSRange(location: 2, length: 4))
    }

    /// `$(` alone has no marker to complete yet.
    @Test func bareInterpolationIsNotAToken() {
        let text = "$("
        let ns = text as NSString
        #expect(IntentExecution.completionToken(in: ns, at: ns.length) == nil)
        #expect(IntentExecution.commandAnchor(in: ns, from: 0, to: 2) == nil)
    }

    // MARK: Multi-word commands (A2)

    /// The fix for the unreachable multi-word entries: a second word extends
    /// the command word before it, so `.timer l` completes `.timer list`.
    @Test func aSecondWordExtendsTheCommandBeforeIt() {
        #expect(token(".timer l") == NSRange(location: 0, length: 8))
        #expect(candidates(".timer l") == [".timer list"])
        #expect(candidates(".timer c") == [".timer cancel all"])
    }

    @Test func everyMultiWordCommandIsTypeable() {
        #expect(candidates(".export n").contains(".export notes"))
        #expect(candidates(".export j").contains(".export json"))
        #expect(candidates(".export c").contains(".export csv"))
        #expect(candidates(".export o").contains(".export obsidian"))
        #expect(candidates(".stopwatch l").contains(".stopwatch list"))
        #expect(candidates(".stopwatch c").contains(".stopwatch cancel all"))
        #expect(candidates(".reminder l").contains(".reminder list"))
        #expect(candidates(".reminder c").contains(".reminder cancel all"))
    }

    /// Every multi-word entry in the registry must be reachable by typing it,
    /// which is what the extension exists to guarantee. Before the fix these
    /// matched nothing at all, because the space ended the token.
    @Test func everyMultiWordEntryIsReachableByTyping() {
        for command in IntentExecution.dotCommands where command.name.contains(" ") {
            let words = command.name.split(separator: " ")
            #expect(words.count >= 2)
            // Type the command word, a space, then the second word's prefix.
            let typed = String(words[0]) + " " + String(words[1].prefix(1))
            #expect(candidates(typed).contains(command.name),
                    "\(command.name) is unreachable by typing `\(typed)`")
        }
    }

    /// The extension must not fire on ordinary text after a command, or the
    /// panel would open over every argument the user types.
    @Test func commandArgumentsDoNotOpenThePanel() {
        #expect(candidates(".timer 5").isEmpty)
        #expect(candidates(".timer 5 soup").isEmpty)
        #expect(candidates(".pomodoro 25/5/4").isEmpty)
        #expect(candidates(".sum 10").isEmpty)
        #expect(candidates(".sum where it > 10").isEmpty)
        #expect(candidates(".export ").isEmpty)
        #expect(candidates(".timer ").isEmpty)
    }

    /// Prose on a line that happens to start with a command word stays text.
    /// The token still spans the command word, but nothing matches it, so the
    /// panel has no rows and does not open over the user's typing.
    @Test func proseAfterACommandWordStaysQuiet() {
        #expect(candidates(".timer soup").isEmpty)
        #expect(token(".timer soup") == NSRange(location: 0, length: 11))
    }

    @Test func aCommandWordMidSentenceDoesNotExtend() {
        // "milk" is not a command, so `.sum` after it stands alone.
        #expect(candidates("milk .sum") == [".sum"])
    }

    // MARK: Escapes

    /// The escape check looks at the text *before* the token, so it is asked
    /// about the token's own location. `completableToken` is what the pane
    /// calls: an escaped line offers nothing, whether the backslash is glued to
    /// the command (no token at all) or separated by a space (token, suppressed).
    @Test func escapedLinesNeverComplete() {
        for text in ["\\.timer l", "\\ .timer l", "  \\.timer l", "\\.sum"] {
            let ns = text as NSString
            #expect(IntentExecution.completableToken(in: ns, at: ns.length) == nil,
                    "\(text.debugDescription) should offer no completion")
        }
        #expect(IntentExecution.completableToken(in: ".timer l" as NSString, at: 8) != nil)
    }

    @Test func unescapedLinesComplete() {
        let ns = ".timer l" as NSString
        #expect(!IntentExecution.isCompletionEscaped(in: ns, at: 0))
        let indented = "  .timer l" as NSString
        #expect(!IntentExecution.isCompletionEscaped(in: indented, at: 2))
    }

    /// An escaped line must not poison the next one.
    @Test func onlyTheCurrentLineIsCheckedForEscapes() {
        let text = "\\.timer l\n.timer l"
        let ns = text as NSString
        #expect(IntentExecution.isCompletionEscaped(in: ns, at: 1), "first line is escaped")
        #expect(!IntentExecution.isCompletionEscaped(in: ns, at: 10), "second line is not")
        #expect(IntentExecution.completableToken(in: ns, at: 18) == NSRange(location: 10, length: 8))
    }
}
