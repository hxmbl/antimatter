import AppKit
import Foundation

// MARK: - Renderer

/// Owns the rendered state of one text view: the parsed elements, the line
/// table, and the lines the selection currently covers. Text edits trigger a
/// full re-render; pure selection changes only re-style the collapsed syntax
/// markers on lines that joined or left the selection, keeping caret moves
/// O(markers touched) instead of O(document).
final class MarkdownHighlighter {
    private var source = ""
    private var elements: [Markdown.Element] = []
    private var lineStarts: [Int] = []
    private var activeLines: Set<Int> = []

    /// Re-parses the text and re-applies Markdown styling to the entire
    /// document. The raw string stays untouched, so editing, undo, copying,
    /// and persistence remain plain-text Markdown; only the display changes.
    ///
    /// Lines under the selection render with their syntax visible (dimmed),
    /// Notion-style; every other line keeps its syntax collapsed.
    func render(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        let baseSize = PaneStyle.fontSize
        storage.setAttributes([
            .font: NSFont.systemFont(ofSize: baseSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle()
        ], range: NSRange(location: 0, length: storage.length))

        let elements = Markdown.parse(text)
        let headings = elements.compactMap { Heading(element: $0) }
        let lineStarts = Self.lineStartOffsets(text)
        let activeLines = Self.activeLineIndexes(
            selectedRanges: textView.selectedRanges,
            lineStarts: lineStarts,
            length: (text as NSString).length
        )

        self.source = text
        self.elements = elements
        self.lineStarts = lineStarts
        self.activeLines = activeLines

        for element in elements {
            switch element.kind {
            case .heading(let level):
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: Markdown.headingFontSize(level: level, base: baseSize)), range: element.range)
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(spacingBefore: 8, spacingAfter: 3), range: element.range)
            case .quote(let level):
                storage.addAttribute(.font, value: italicFont(ofSize: contentFontSize(of: element, headings: headings, base: baseSize)), range: element.range)
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(headIndent: CGFloat(14 * level), firstLineHeadIndent: CGFloat(14 * level)), range: element.range)
            case .codeBlock:
                var range = element.range
                if range.location + range.length < storage.length {
                    range.length += 1
                }
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular), range: range)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: range)
            case .language, .marker, .hr, .tablePipe, .taskMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: element.range)
            case .taskBody(let done):
                if done {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: element.range)
                }
            case .tableHeader:
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseSize), range: element.range)
            case .strong:
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: contentFontSize(of: element, headings: headings, base: baseSize)), range: element.range)
            case .emphasis:
                storage.addAttribute(.font, value: italicFont(ofSize: contentFontSize(of: element, headings: headings, base: baseSize)), range: element.range)
            case .code:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular), range: element.range)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: element.range)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
            case .link(let urlString):
                if let url = URL(string: urlString) {
                    storage.addAttribute(.link, value: url, range: element.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: element.range)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
                    storage.addAttribute(.toolTip, value: urlString, range: element.range)
                }
            case .listItem(let level):
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(headIndent: CGFloat(16 * level), firstLineHeadIndent: 0), range: element.range)
            case .hidden, .escape:
                if activeLines.contains(Self.lineIndex(at: element.range.location, lineStarts: lineStarts)) {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize), range: element.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: element.range)
                } else {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: element.range)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: element.range)
                }
            }
        }
    }

    /// Renders only what changed since the last render: falls back to a full
    /// render after a text edit, otherwise re-styles just the markers on
    /// lines the selection entered or left.
    func refresh(_ textView: NSTextView) {
        guard textView.string == source else {
            render(textView)
            return
        }
        let newActiveLines = Self.activeLineIndexes(
            selectedRanges: textView.selectedRanges,
            lineStarts: lineStarts,
            length: (source as NSString).length
        )
        let entering = newActiveLines.subtracting(activeLines)
        let leaving = activeLines.subtracting(newActiveLines)
        guard !entering.isEmpty || !leaving.isEmpty else { return }
        activeLines = newActiveLines
        guard let storage = textView.textStorage else { return }
        let baseSize = PaneStyle.fontSize
        for element in elements where element.kind.isSyntaxMarker {
            let line = Self.lineIndex(at: element.range.location, lineStarts: lineStarts)
            if entering.contains(line) {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize), range: element.range)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: element.range)
            } else if leaving.contains(line) {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: element.range)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: element.range)
            }
        }
    }

    // MARK: Font sizing

    private struct Heading {
        let range: NSRange
        let level: Int

        init?(element: Markdown.Element) {
            guard case .heading(let parsedLevel) = element.kind else { return nil }
            range = element.range
            level = parsedLevel
        }
    }

    /// Inline styles inside a heading keep the heading's scale. Headings are
    /// sorted by location, so containment is a binary search, not a sweep.
    private func contentFontSize(of element: Markdown.Element, headings: [Heading], base: CGFloat) -> CGFloat {
        var lower = 0
        var upper = headings.count - 1
        var candidate: Int?
        while lower <= upper {
            let middle = (lower + upper) / 2
            if headings[middle].range.location <= element.range.location {
                candidate = middle
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        guard let candidate, NSLocationInRange(element.range.location, headings[candidate].range) else { return base }
        return Markdown.headingFontSize(level: headings[candidate].level, base: base)
    }

    private func italicFont(ofSize size: CGFloat) -> NSFont {
        NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }

    // MARK: Line geometry

    private static func lineStartOffsets(_ text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            if unit == 0x0A { starts.append(offset + 1) }
            offset += 1
        }
        return starts
    }

    private static func lineIndex(at location: Int, lineStarts: [Int]) -> Int {
        var lower = 0
        var upper = lineStarts.count - 1
        while lower < upper {
            let mid = (lower + upper + 1) / 2
            if lineStarts[mid] <= location {
                lower = mid
            } else {
                upper = mid - 1
            }
        }
        return lower
    }

    private static func activeLineIndexes(selectedRanges: [NSValue], lineStarts: [Int], length: Int) -> Set<Int> {
        var set: Set<Int> = []
        for proto in selectedRanges {
            let range = proto.rangeValue
            guard range.length >= 0 else { continue }
            let firstLocation = min(max(0, range.location), length)
            let lastLocation = min(max(0, range.length > 0 ? NSMaxRange(range) - 1 : range.location), length)
            let first = lineIndex(at: firstLocation, lineStarts: lineStarts)
            let last = lineIndex(at: lastLocation, lineStarts: lineStarts)
            for index in first...last where index >= 0 && index < lineStarts.count {
                set.insert(index)
            }
        }
        return set
    }

    // MARK: Paragraph style

    private func paragraphStyle(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = PaneStyle.lineSpacing
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent
        return style
    }
}

extension Markdown {
    /// Full render for callers without a persistent highlighter.
    ///
    /// Lines under the selection render with their syntax visible (dimmed),
    /// Notion-style; every other line keeps its syntax collapsed.
    static func highlight(_ textView: NSTextView) {
        MarkdownHighlighter().render(textView)
    }

    static func headingFontSize(level: Int, base: CGFloat) -> CGFloat {
        base + CGFloat(max(0, 12 - 2 * level))
    }
}
