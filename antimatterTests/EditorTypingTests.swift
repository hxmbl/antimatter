import AppKit
import SwiftUI
import Testing
@testable import antimatter

/// The synchronous half of heading styling: attributes chosen for the next
/// typed character. The full Markdown pass stays deferred, so these tests pin
/// the part that has to be right before the glyph is inserted.
@MainActor
struct EditorTypingAttributesTests {

    @Test func headingLineUsesTheHeadingFontAndSpacing() {
        let text = "# Heading"
        let attributes = PaneEditor.typingAttributes(forCaretAt: 3, in: text, fontSize: 13)

        let font = attributes[.font] as? NSFont
        #expect(font?.pointSize == Markdown.headingFontSize(level: 1, base: 13))

        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        #expect(style?.paragraphSpacingBefore == MarkdownHighlighter.headingSpacingBefore)
        #expect(style?.paragraphSpacing == MarkdownHighlighter.headingSpacingAfter)
    }

    @Test func bodyLineUsesTheBodyFont() {
        let attributes = PaneEditor.typingAttributes(forCaretAt: 2, in: "plain text", fontSize: 13)
        let font = attributes[.font] as? NSFont
        #expect(font?.pointSize == 13)

        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        #expect(style?.paragraphSpacingBefore == 0)
        #expect(style?.paragraphSpacing == 0)
    }

    @Test func onlyTheCaretLineDecidesTheStyle() {
        let text = "plain\n### Heading"
        let heading = (text as NSString).range(of: "### Heading")
        let headingAttributes = PaneEditor.typingAttributes(
            forCaretAt: heading.location + 4, in: text, fontSize: 13)
        #expect((headingAttributes[.font] as? NSFont)?.pointSize
                == Markdown.headingFontSize(level: 3, base: 13))

        let bodyAttributes = PaneEditor.typingAttributes(forCaretAt: 1, in: text, fontSize: 13)
        #expect((bodyAttributes[.font] as? NSFont)?.pointSize == 13)
    }

    @Test func caretAtTheEndOfAHeadingStillUsesTheHeadingFont() {
        let text = "# Hi"
        let attributes = PaneEditor.typingAttributes(
            forCaretAt: (text as NSString).length, in: text, fontSize: 13)
        #expect((attributes[.font] as? NSFont)?.pointSize
                == Markdown.headingFontSize(level: 1, base: 13))
    }

    @Test func freshLineAfterAHeadingUsesTheBodyFont() {
        let text = "# Heading\n"
        let attributes = PaneEditor.typingAttributes(
            forCaretAt: (text as NSString).length, in: text, fontSize: 13)
        #expect((attributes[.font] as? NSFont)?.pointSize == 13)
    }

    /// End-to-end through the coordinator: the character inserted at the end
    /// of a heading is already heading-sized, without waiting for `render`.
    @Test func typedCharacterLandsWithHeadingAttributes() {
        let coordinator = PaneEditor.Coordinator(
            text: .constant(""),
            status: .constant(FooterStatus()),
            topTextLevel: .constant(0),
            noteStore: NoteStore.shared)
        let view = PaneTextView()
        view.string = "# Hello"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        coordinator.syncTypingAttributes(view)
        view.insertText("!", replacementRange: view.selectedRange())

        let font = view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == Markdown.headingFontSize(level: 1, base: PaneStyle.fontSize))
    }

    @Test func typedCharacterOnABodyLineLandsAtTheBodySize() {
        let coordinator = PaneEditor.Coordinator(
            text: .constant(""),
            status: .constant(FooterStatus()),
            topTextLevel: .constant(0),
            noteStore: NoteStore.shared)
        let view = PaneTextView()
        view.string = "plain"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        coordinator.syncTypingAttributes(view)
        view.insertText("!", replacementRange: view.selectedRange())

        let font = view.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == PaneStyle.fontSize)
    }
}
