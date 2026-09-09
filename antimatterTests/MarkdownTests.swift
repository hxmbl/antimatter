import AppKit
import Foundation
import Testing
@testable import antimatter

@MainActor
struct MarkdownTests {

    private func parse(_ source: String) -> [Markdown.Element] {
        Markdown.parse(source)
    }

    private func kinds(_ source: String) -> [Markdown.Element.Kind] {
        parse(source).map(\.kind)
    }

    private func containsHeading(_ elements: [Markdown.Element]) -> Bool {
        elements.contains { element in
            if case .heading = element.kind { return true }
            return false
        }
    }

    // MARK: Headings

    @Test func headingsAreRecognisedFromLevel1Through6() {
        for level in 1...Markdown.maxHeadingLevel {
            let source = String(repeating: "#", count: level) + " Title"
            #expect(parse(source).contains { $0.kind == .heading(level: level) })
        }
    }

    @Test func sevenHashesIsNotAHeading() {
        #expect(!containsHeading(parse(String(repeating: "#", count: 7) + " too deep")))
    }

    @Test func hashRequiresAFollowingSpace() {
        #expect(!containsHeading(parse("#tag")))
    }

    @Test func headingHashesAreHidden() {
        let elements = parse("## Hi")
        #expect(elements[0].kind == .heading(level: 2))
        #expect(elements[0].range == NSRange(location: 0, length: 5))
        #expect(elements.contains { $0.kind == .hidden && $0.range == NSRange(location: 0, length: 2) })
    }

    @Test func setextHeadingsUseUnderlines() {
        let h1 = parse("Title\n=====")
        #expect(h1.contains { $0.kind == .heading(level: 1) })
        #expect(h1.contains { $0.kind == .hidden && $0.range.length == 5 })

        let h2 = parse("Title\n---")
        #expect(h2.contains { $0.kind == .heading(level: 2) })

        let multiline = parse("Two words\nmore\n===")
        let heading = multiline.first { element in
            if case .heading = element.kind { return true }
            return false
        }
        #expect(heading?.range.lowerBound == 0)
    }

    @Test func dashesAloneAreNotSetextWithoutAPrecedingParagraph() {
        #expect(!containsHeading(parse("---")))
    }

    // MARK: Thematic breaks

    @Test func thematicBreaksAreRecognised() {
        for marker in ["---", "***", "___", "- - -", "* * *"] {
            #expect(kinds(marker).contains(.hr))
        }
    }

    @Test func twoCharactersIsNotAThematicBreak() {
        #expect(!kinds("--").contains(.hr))
        #expect(!kinds("**bold**").contains(.hr))
    }

    // MARK: Block quotes

    @Test func blockquoteHidesArrowAndStylesContent() {
        let elements = parse("> note **loud**")
        #expect(elements.first?.kind == .hidden)
        #expect(elements.contains { $0.kind == .quote(level: 1) })
        #expect(elements.contains { $0.kind == .hidden && $0.range == NSRange(location: 0, length: 1) })
        #expect(elements.contains { $0.kind == .strong })
    }

    @Test func nestedBlockquotesTrackTheirLevel() {
        #expect(parse("> a").contains { $0.kind == .quote(level: 1) })
        #expect(parse(">> b").contains { $0.kind == .quote(level: 2) })
    }

    @Test func lazyBlockquoteWithoutSpaceWorks() {
        #expect(parse(">no space").contains { $0.kind == .quote(level: 1) })
    }

    @Test func loneGreaterThanInTextIsLiteral() {
        #expect(parse("a > b").isEmpty)
    }

    // MARK: Lists

    @Test func bulletMarkersStayDimmed() {
        for bullet in ["- item", "* item", "+ item"] {
            let elements = parse(bullet)
            #expect(elements.map(\.kind) == [.listItem(level: 0), .marker])
            #expect(elements[1].range == NSRange(location: 0, length: 1))
        }
    }

    @Test func orderedListMarkerCoversTheNumber() {
        let elements = parse("12. done")
        #expect(elements.map(\.kind) == [.listItem(level: 0), .marker])
        #expect(elements[1].range == NSRange(location: 0, length: 3))
    }

    @Test func listNestingComesFromIndentation() {
        #expect(parse("- top").contains { $0.kind == .listItem(level: 0) })
        #expect(parse("  - mid").contains { $0.kind == .listItem(level: 1) })
        #expect(parse("    - deep").contains { $0.kind == .listItem(level: 2) })
    }

    @Test func bulletsRequireAFollowingSpace() {
        #expect(parse("-nospace").isEmpty)
        #expect(parse("--").isEmpty)
        #expect(parse("TODO - fix this").isEmpty)
    }

    @Test func decimalsAndDatesAreNotLists() {
        #expect(parse("1.5 million").isEmpty)
        #expect(parse("2026-08-22").isEmpty)
    }

    // MARK: Task lists

    @Test func uncheckedTaskMarksItsBracket() {
        let elements = parse("- [ ] milk")
        #expect(elements.contains { $0.kind == .taskMarker(done: false) && $0.range.location == 2 && $0.range.length == 3 })
        #expect(elements.contains { $0.kind == .taskBody(done: false) })
    }

    @Test func checkedTaskStrikesItsBody() {
        let elements = parse("- [x] done deal")
        #expect(elements.contains { $0.kind == .taskMarker(done: true) })
        #expect(elements.contains { $0.kind == .taskBody(done: true) && $0.range.location == 6 })
    }

    // MARK: Fenced code

    @Test func fencedCodeBlocksStyleTheirLines() {
        let elements = parse("```swift\nlet x = 1\n```")
        #expect(elements.contains { $0.kind == .hidden && $0.range == NSRange(location: 0, length: 3) })
        #expect(elements.contains { $0.kind == .language && $0.range == NSRange(location: 3, length: 5) })
        #expect(elements.contains { $0.kind == .codeBlock && $0.range.location == 9 })
        #expect(elements.contains { $0.kind == .hidden && $0.range.location == 19 })
    }

    @Test func unterminatedFenceConsumesTheRest() {
        let elements = parse("```\nstill code")
        let blocks = elements.filter { $0.kind == .codeBlock }
        #expect(blocks.count == 1)
        #expect(blocks[0].range.location == 4)
    }

    @Test func tildeFencesWork() {
        let elements = parse("~~~\ncode\n~~~")
        #expect(elements.contains { $0.kind == .codeBlock })
    }

    @Test func closingFenceNeedsMatchingLengths() {
        let elements = parse("````\ncode\n```\nmore code")
        let blocks = elements.filter { $0.kind == .codeBlock }
        #expect(blocks.count == 3)
    }

    // MARK: Tables

    @Test func tablesMarkPipesAndBoldTheHeader() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let elements = parse(source)
        #expect(elements.contains { $0.kind == .tableHeader })
        #expect(elements.filter { $0.kind == .tablePipe }.count == 6)
        #expect(elements.contains { $0.kind == .marker && $0.range.location == 10 && $0.range.length == 9 })
        #expect(elements.contains { $0.kind == .emphasis || $0.kind == .strong } == false)
    }

    @Test func pipeLineWithoutDividerIsPlainText() {
        #expect(parse("just | one line").isEmpty)
    }

    // MARK: Inline spans

    @Test func strongSpanCollapsesItsMarkers() {
        let elements = parse("**bold**")
        #expect(elements.contains { $0.kind == .strong && $0.range == NSRange(location: 2, length: 4) })
        #expect(elements.contains { $0.kind == .hidden && $0.range == NSRange(location: 0, length: 2) })
        #expect(elements.contains { $0.kind == .hidden && $0.range == NSRange(location: 6, length: 2) })
    }

    @Test func emphasisCodeAndStrikeSpans() {
        let emphasis = parse("*it*")
        #expect(emphasis.contains { $0.kind == .emphasis && $0.range == NSRange(location: 1, length: 2) })

        let code = parse("`code`")
        #expect(code.contains { $0.kind == .code && $0.range == NSRange(location: 0, length: 6) })

        let strike = parse("~~gone~~")
        #expect(strike.contains { $0.kind == .strike && $0.range == NSRange(location: 2, length: 4) })
    }

    @Test func doubleTickCodeSpansMatchEqualLengths() {
        let elements = parse("``a ` b``")
        #expect(elements.contains { $0.kind == .code && $0.range.length == 9 })
    }

    @Test func singleTildeIsLiteral() {
        #expect(!parse("a ~ b").map(\.kind).contains(.strike))
    }

    @Test func unterminatedDelimitersStayLiteral() {
        #expect(!parse("**nope").map(\.kind).contains(.strong))
        #expect(!parse("*nope").map(\.kind).contains(.emphasis))
        #expect(!parse("~~nope").map(\.kind).contains(.strike))
    }

    // MARK: Links

    @Test func inlineLinkCollapsesSyntaxAndKeepsLabel() {
        let elements = parse("[label](https://example.com)")
        #expect(elements.contains { $0.kind == .link("https://example.com") && $0.range == NSRange(location: 1, length: 5) })
        #expect(elements.contains { $0.kind == .hidden && $0.range == NSRange(location: 0, length: 1) })
        #expect(elements.contains { $0.kind == .hidden && $0.range == NSRange(location: 6, length: 22) })
    }

    @Test func imageRendersAsALinkOverItsAltText() {
        let elements = parse("![cat](https://example.com/cat.png)")
        #expect(elements.contains { $0.kind == .link("https://example.com/cat.png") && $0.range.location == 2 })
    }

    @Test func autolinksWork() {
        let elements = parse("<https://example.com>")
        #expect(elements.contains { $0.kind == .link("https://example.com") && $0.range == NSRange(location: 1, length: 19) })
    }

    @Test func mailtoAutolinksWork() {
        #expect(parse("<mailto:x@y.com>").contains { $0.kind == .link("mailto:x@y.com") })
    }

    @Test func bareURLsBecomeLinksAndDropTrailingPunctuation() {
        let elements = parse("see https://example.com.")
        #expect(elements.contains { $0.kind == .link("https://example.com") })
    }

    @Test func bareWwwURLsLinkToTheirHTTPSForm() {
        let elements = parse("visit www.example.com today")
        #expect(elements.contains { $0.kind == .link("https://www.example.com") && $0.range.location == 6 && $0.range.length == 15 })
        #expect(!kinds("a wordy sentence").contains(.link("")))
    }

    @Test func schemelessHostsNeedADomain() {
        // Regression: a bare "www" or "www." used to crash the parser while
        // slicing the host; it must simply stay text.
        #expect(parse("www").isEmpty)
        #expect(parse("www.").isEmpty)
        #expect(parse("check www. here").isEmpty)
        #expect(parse("www.a").isEmpty)
        #expect(parse("www.foo.co.uk/b?x=1 end").contains { $0.kind == .link("https://www.foo.co.uk/b?x=1") })
    }

    @Test func bareMailtoURLsBecomeLinks() {
        #expect(parse("mail me at mailto:x@y.com.").contains { $0.kind == .link("mailto:x@y.com") })
    }

    /// The renderer applies block styles before their inner hidden markers;
    /// that ordering contract is what the sort tiebreaker guarantees. Strong
    /// and emphasis spans exclude their markers, so the sorted order puts
    /// the leading hidden range first; code spans are inclusive.
    @Test func sameLocationElementsKeepInsertionOrder() {
        #expect(kinds("**b**") == [.hidden, .strong, .hidden])
        #expect(kinds("`c`") == [.code, .hidden, .hidden])
        #expect(kinds("# T") == [.heading(level: 1), .hidden])
    }

    @Test func invalidLinksStayLiteral() {
        #expect(!kinds("[no url]()").contains { if case .link = $0 { return true }; return false })
        #expect(kinds("https://exa mple.com").contains(.link("https://exa")))
    }

    // MARK: Escapes

    @Test func escapedAsteriskDoesNotOpenASpan() {
        let elements = parse("2 \\* 3 = 6")
        #expect(!elements.map(\.kind).contains(.strong))
        #expect(!elements.map(\.kind).contains(.emphasis))
        #expect(elements.map(\.kind).contains(.escape))
    }

    @Test func escapedHashDoesNotStartAHeading() {
        let elements = parse("\\# not a heading")
        #expect(!containsHeading(elements))
        #expect(elements.first?.kind == .escape)
        #expect(elements.first?.range == NSRange(location: 0, length: 1))
    }

    @Test func doubleBackslashEscapesItself() {
        let elements = parse("\\\\")
        #expect(elements.map(\.kind) == [.escape])
        #expect(elements[0].range == NSRange(location: 0, length: 1))
    }

    @Test func escapeWorksInsideCodeSpans() {
        let elements = parse("`a\\`b`")
        #expect(elements.contains { $0.kind == .code && $0.range.length == 6 })
    }

    @Test func trailingBackslashAloneIsAnEscape() {
        let elements = parse("abc\\")
        #expect(elements.map(\.kind) == [.escape])
        #expect(elements[0].range == NSRange(location: 3, length: 1))
    }

    @Test func escapedPipeSurvivesTableSplitting() {
        let elements = parse("| a | b |\n|---|---|\n| x \\| y | 2 |")
        #expect(elements.contains { $0.kind == .tableHeader })
        #expect(elements.contains { $0.kind == .link("") } == false)
    }

    // MARK: Combinations

    @Test func inlineStylesWorkInsideHeadings() {
        let elements = parse("## Hi **there**")
        #expect(containsHeading(elements))
        let strong = elements.first { $0.kind == .strong }
        #expect(strong?.range == NSRange(location: 8, length: 5))
    }

    @Test func linesParseIndependently() {
        let elements = parse("# Top\nplain *mid*\n## Bottom")
        let headings = elements.filter { element in
            if case .heading = element.kind { return true }
            return false
        }
        #expect(headings.count == 2)
        #expect(headings[0].kind == .heading(level: 1))
        #expect(headings[1].kind == .heading(level: 2))
        #expect(elements.contains { $0.kind == .emphasis })
    }

    @Test func plainTextProducesNoElements() {
        #expect(parse("hello world").isEmpty)
    }

    // MARK: Tracking-parameter stripping

    @Test func trackingParametersAreStrippedFromInlineLinks() {
        let elements = parse("[label](https://example.com/page?utm_source=x&id=42)")
        #expect(elements.contains { $0.kind == .link("https://example.com/page?id=42") })
    }

    @Test func utmParametersAreStrippedFromAutolinks() {
        let elements = parse("<https://example.com/?utm_campaign=summer&fbclid=abc>")
        #expect(elements.contains { $0.kind == .link("https://example.com/") })
    }

    @Test func bareURLsDropTrackingParameters() {
        let elements = parse("go to https://example.com/?gclid=xyz&utm_source=ad now")
        #expect(elements.contains { $0.kind == .link("https://example.com/") })
    }

    @Test func stripTrackingKeepsNonTrackingParameters() {
        let cleaned = Markdown.stripTrackingParameters(from: "https://example.com/page?a=1&utm_medium=email&b=2")
        #expect(cleaned == "https://example.com/page?a=1&b=2")
    }

    @Test func stripTrackingLeavesCleanURLsUntouched() {
        let url = "https://example.com/page?a=1"
        #expect(Markdown.stripTrackingParameters(from: url) == url)
    }

    @Test func stripTrackingRemovesAllLeavingCleanBase() {
        let cleaned = Markdown.stripTrackingParameters(from: "https://example.com/page?utm_source=x")
        #expect(cleaned == "https://example.com/page")
    }
}

@MainActor
struct MarkdownHighlightTests {

    @Test func headingRendersBoldInsideATextView() {
        let textView = NSTextView()
        textView.string = "# Title\nplain"
        Markdown.highlight(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let expected = NSFont.boldSystemFont(ofSize: Markdown.headingFontSize(level: 1, base: PaneStyle.fontSize))
        #expect(headingFont == expected)

        let bodyFont = storage.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        #expect(bodyFont == NSFont.systemFont(ofSize: PaneStyle.fontSize))
    }

    @Test func syntaxMarkersCollapseAwayFromTheCaret() {
        let textView = NSTextView()
        textView.string = "**x**\naway"
        textView.selectedRange = NSRange(location: 7, length: 0)
        Markdown.highlight(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 1)
        let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.clear)

        let bodyFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(bodyFont == NSFont.boldSystemFont(ofSize: PaneStyle.fontSize))
    }

    @Test func theCaretsOwnLineShowsItsSyntaxNotionStyle() {
        let textView = NSTextView()
        textView.string = "# Title\nplain"
        textView.selectedRange = NSRange(location: 2, length: 0)
        Markdown.highlight(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        let revealedFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(revealedFont?.pointSize == PaneStyle.fontSize)
        let revealedColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(revealedColor == NSColor.secondaryLabelColor)
        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(headingFont == NSFont.boldSystemFont(ofSize: Markdown.headingFontSize(level: 1, base: PaneStyle.fontSize)))

        // Moving the caret off the line re-renders it.
        textView.selectedRange = NSRange(location: 10, length: 0)
        Markdown.highlight(textView)
        let collapsedFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(collapsedFont?.pointSize == 1)
        let collapsedColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(collapsedColor == NSColor.clear)
    }

    @Test func inlineMarkersRevealOnlyOnTheirOwnLine() {
        let textView = NSTextView()
        textView.string = "one **two** three\nfour **five** six"
        textView.selectedRange = NSRange(location: 20, length: 0)
        Markdown.highlight(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        let line1Marker = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        #expect(line1Marker?.pointSize == 1)
        let line2Marker = storage.attribute(.font, at: 24, effectiveRange: nil) as? NSFont
        #expect(line2Marker?.pointSize == PaneStyle.fontSize)
    }

    @Test func listMarkerIsDimmedAndTaskBodyStrikesWhenDone() {
        let textView = NSTextView()
        textView.string = "- [x] finished"
        Markdown.highlight(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(markerColor == NSColor.secondaryLabelColor)

        let strike = storage.attribute(.strikethroughStyle, at: 6, effectiveRange: nil)
        #expect(strike != nil)
    }

    @Test func linksCarryURLAndTooltipAttributes() {
        let textView = NSTextView()
        textView.string = "[site](https://example.com)\naway"
        textView.selectedRange = NSRange(location: 29, length: 0)
        Markdown.highlight(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        let link = storage.attribute(.link, at: 1, effectiveRange: nil) as? URL
        #expect(link == URL(string: "https://example.com"))
        let tooltip = storage.attribute(.toolTip, at: 1, effectiveRange: nil) as? String
        #expect(tooltip == "https://example.com")

        let hiddenColor = storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor
        #expect(hiddenColor == NSColor.clear)
    }

    @Test func codeBlocksGetMonospaceFontAndBackground() {
        let textView = NSTextView()
        textView.string = "```\nlet x = 1\n```"
        Markdown.highlight(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        let font = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        #expect(font == NSFont.monospacedSystemFont(ofSize: PaneStyle.fontSize - 1, weight: .regular))
        let background = storage.attribute(.backgroundColor, at: 4, effectiveRange: nil)
        #expect(background != nil)
    }
}

@MainActor
struct MarkdownHighlighterTests {

    @Test func renderingNeverChangesMarkdownSource() {
        let text = "# Café — 2\n\n`naïve` **世界**"
        let textView = NSTextView()
        let highlighter = MarkdownHighlighter()
        textView.string = text

        highlighter.render(textView)

        #expect(textView.string == text)
    }

    @Test func selectionChangesRestyleOnlyMarkersNotTheDocument() {
        let textView = NSTextView()
        let highlighter = MarkdownHighlighter()
        textView.string = "**x**\naway"
        highlighter.render(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        // Caret moves to line 2: line 1 markers collapse.
        textView.selectedRange = NSRange(location: 7, length: 0)
        highlighter.refresh(textView)
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 1)

        // Caret returns: markers reveal without a full re-render.
        textView.selectedRange = NSRange(location: 1, length: 0)
        highlighter.refresh(textView)
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == PaneStyle.fontSize)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.secondaryLabelColor)
    }

    @Test func refreshAfterATextEditFallsBackToAFullRender() {
        let textView = NSTextView()
        let highlighter = MarkdownHighlighter()
        textView.string = "plain"
        highlighter.render(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        textView.string = "plain **loud**"
        highlighter.refresh(textView)
        #expect(storage.attribute(.font, at: 9, effectiveRange: nil) as? NSFont == NSFont.boldSystemFont(ofSize: PaneStyle.fontSize))
    }

    @Test func repeatedRefreshWithoutChangeLeavesStylingStable() {
        let textView = NSTextView()
        let highlighter = MarkdownHighlighter()
        textView.string = "# Title\nbody"
        highlighter.render(textView)
        guard let storage = textView.textStorage else {
            Issue.record("no text storage")
            return
        }

        textView.selectedRange = NSRange(location: 2, length: 0)
        highlighter.refresh(textView)
        highlighter.refresh(textView)
        #expect(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == NSFont.systemFont(ofSize: PaneStyle.fontSize))
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.secondaryLabelColor)
    }
}
