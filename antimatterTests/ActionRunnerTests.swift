import Foundation
import Testing
@testable import antimatter

@MainActor
struct ActionRunnerTests {

    /// `ActionRunner.run` turns a command line into an outcome and appends the
    /// committed aggregate line to the active note.
    @Test func sumAppendsResultAndReportsValue() {
        _ = NoteStore.shared.create(text: "5\n3\n10\n")
        defer { resetActiveNote() }
        let outcome = ActionRunner.run(".sum")
        #expect(outcome.ok == true)
        #expect(outcome.message == ".sum = 18")
        #expect(NoteStore.shared.activeNote.text.hasSuffix(".sum = 18"))
    }

    @Test func calculationAppendsAndReturnsResult() {
        _ = NoteStore.shared.create(text: "")
        defer { resetActiveNote() }
        let outcome = ActionRunner.run("384 * 27")
        #expect(outcome.ok == true)
        #expect(outcome.message == "10368")
        #expect(NoteStore.shared.activeNote.text.hasSuffix("384 * 27 = 10368"))
    }

    @Test func emptyAggregateIsAFailure() {
        _ = NoteStore.shared.create(text: "no numbers here")
        defer { resetActiveNote() }
        let outcome = ActionRunner.run(".sum")
        #expect(outcome.ok == false)
    }

    @Test func newNoteReportsItsTitle() {
        defer { resetActiveNote() }
        let outcome = ActionRunner.create(text: "hello")
        #expect(outcome.ok == true)
        #expect(outcome.message == "New note — hello")
    }

    @Test func appendAddsToActiveNote() {
        _ = NoteStore.shared.create(text: "first")
        defer { resetActiveNote() }
        let outcome = ActionRunner.append(text: "second")
        #expect(outcome.ok == true)
        #expect(NoteStore.shared.activeNote.text == "first\nsecond")
    }

    @Test func nonCommandProseIsANoOp() {
        _ = NoteStore.shared.create(text: "some ordinary notes")
        defer { resetActiveNote() }
        let outcome = ActionRunner.run("grocery run and milk")
        #expect(outcome.ok == false)
        #expect(NoteStore.shared.activeNote.text == "some ordinary notes")
    }

    @Test func naturalDurationReadsNaturally() {
        #expect(ActionRunner.naturalDuration(90) == "1 min 30 sec")
        #expect(ActionRunner.naturalDuration(25 * 60) == "25 min")
        #expect(ActionRunner.naturalDuration(3600) == "1 h")
        #expect(ActionRunner.naturalDuration(3900) == "1 h 5 min")
    }

    /// Drops the test-created notes so the suite's shared singleton doesn't
    /// leak state between cases; the isolated storage dir is throwaway anyway.
    private func resetActiveNote() {
        var note = NoteStore.shared.activeNote
        note.text = ""
        note.modifiedAt = Date()
        NoteStore.shared.activeNote = note
        NoteStore.shared.flush()
    }
}