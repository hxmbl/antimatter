import AppKit
import Foundation
import Testing
@testable import antimatter

/// The 10k-line large-note benchmark (STRM-684). Antimatter re-renders the
/// whole note's Markdown on each keystroke, so the parse + render pair is
/// the hot path that decides whether a large note still types smoothly.
///
/// The budgets are gross-regression tripwires, not targets: an order of
/// magnitude of headroom is deliberate, so CI hardware noise never flakes
/// the suite. If either test fails, that is the signal to do the
/// line-scoped Markdown re-render from the review — optimize only then.
struct LargeNoteBenchmarkTests {

    /// A 10,000-line note mixing the constructs the parser special-cases:
    /// headings, lists, tasks, tables, code fences, bold/italic, links and
    /// plain prose, so the benchmark cannot pass on a degenerate input.
    private func makeLargeNote(lineCount: Int = 10_000) -> String {
        let cycle = [
            "# Heading",
            "plain prose line with a few words in it",
            "- list item",
            "- [ ] task to do",
            "**bold** and *italic* and `code`",
            "| cell | other |",
            "```swift",
            "let value = 42",
            "```",
            "a link to https://example.com and **strong** text",
        ]
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for lineIndex in 0..<lineCount {
            lines.append(cycle[lineIndex % cycle.count])
        }
        return lines.joined(separator: "\n")
    }

    @Test func parseStaysWithinBudgetOnATenThousandLineNote() {
        let note = makeLargeNote()
        #expect(note.components(separatedBy: "\n").count == 10_000)
        let clock = ContinuousClock()
        var elementCount = 0
        let elapsed = clock.measure {
            elementCount = Markdown.parse(note).count
        }
        #expect(elementCount > 0)
        #expect(elapsed < .seconds(1),
                "Markdown.parse took \(elapsed) on 10k lines — past the regression budget")
    }

    @Test func fullRenderStaysWithinBudgetOnATenThousandLineNote() {
        let note = makeLargeNote()
        let storage = NSTextStorage(string: note)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 480, height: 0))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 600), textContainer: container)
        let highlighter = MarkdownHighlighter()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            highlighter.render(textView)
        }
        #expect(elapsed < .seconds(5),
                "MarkdownHighlighter.render took \(elapsed) on 10k lines — past the regression budget")
    }
}
