import AppKit
import Foundation
import Testing

@testable import antimatter

struct DashSubstitutionTests {

    private func rewrite(_ o: DashSubstitution.Outcome) -> (NSRange, String)? {
        if case .rewrite(let range, let text) = o { return (range, text) }
        return nil
    }

    @Test func singleHyphenAccepted() {
        #expect(DashSubstitution.outcome(typing: "-", into: "x", at: 1) == .accept)
    }

    @Test func secondHyphenAcceptedDeferred() {
        #expect(DashSubstitution.outcome(typing: "-", into: "x-", at: 2) == .accept)
    }

    // `--` followed by a letter → `–a` replaces the two hyphens.
    @Test func enDashWhenLetterFollows() {
        let o = DashSubstitution.outcome(typing: "a", into: "warm--", at: 6)
        guard let (range, text) = rewrite(o) else {
            Issue.record("expected rewrite, got \(o)")
            return
        }
        #expect(range == NSRange(location: 4, length: 2))
        #expect(text == "–a")
    }

    // `--` followed by a space (inline) → `– ` replaces the two hyphens.
    @Test func enDashWhenSpaceFollowsInline() {
        let o = DashSubstitution.outcome(typing: " ", into: "warm--", at: 6)
        guard let (range, text) = rewrite(o) else {
            Issue.record("expected rewrite, got \(o)")
            return
        }
        #expect(range == NSRange(location: 4, length: 2))
        #expect(text == "– ")
    }

    // Typing a third hyphen into an inline `--` → em dash, run absorbed.
    @Test func thirdHyphenInlineMakesEmDash() {
        let o = DashSubstitution.outcome(typing: "-", into: "warm--", at: 6)
        guard let (range, text) = rewrite(o) else {
            Issue.record("expected rewrite, got \(o)")
            return
        }
        #expect(range == NSRange(location: 4, length: 3))
        #expect(text == "—")
    }

    // `---` + space at line start stays raw (horizontal rule).
    @Test func tripleHyphenOwnLineStaysRaw() {
        #expect(DashSubstitution.outcome(typing: " ", into: "---", at: 3) == .accept)
    }

    // `---` + space inline → em dash + the space.
    @Test func tripleHyphenInlineWithSpaceMakesEmDash() {
        let o = DashSubstitution.outcome(typing: " ", into: "x---", at: 4)
        guard let (range, text) = rewrite(o) else {
            Issue.record("expected rewrite, got \(o)")
            return
        }
        #expect(range == NSRange(location: 1, length: 3))
        #expect(text == "— ")
    }

    // A lone hyphen at start, then a letter → still deferred, no change yet.
    @Test func loneHyphenStartStayDeferred() {
        #expect(DashSubstitution.outcome(typing: "a", into: "-", at: 1) == .accept)
    }

    // A `--` at the very start followed by a letter becomes `–a`.
    @Test func enDashFromLineStart() {
        let o = DashSubstitution.outcome(typing: "a", into: "--", at: 2)
        guard let (range, text) = rewrite(o) else {
            Issue.record("expected rewrite, got \(o)")
            return
        }
        #expect(range == NSRange(location: 0, length: 2))
        #expect(text == "–a")
    }
}