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
}
