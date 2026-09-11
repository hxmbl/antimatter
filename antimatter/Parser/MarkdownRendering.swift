import AppKit
import Foundation

// MARK: - Renderer

/// Owns the rendered state of one text view: the parsed elements, the line
/// table, and the lines the selection currently covers. Text edits trigger a
/// full re-render. Selection changes never alter the document's glyph
/// attributes, so caret movement cannot make Unicode graphemes reflow or
/// expose display-only replacement artifacts. Syntax-only characters are
/// hidden with stable attributes on every render rather than toggled based on
/// the caret.
final class MarkdownHighlighter {
    private var source = ""
    private var elements: [Markdown.Element] = []

    /// Re-parses the text and re-applies Markdown styling to the entire
    /// document. The raw string stays untouched, so editing, undo, copying,
    /// and persistence remain plain-text Markdown; only the display changes.
    ///
    /// Markdown syntax-only characters stay hidden. Keeping those attributes
    /// stable avoids caret-dependent glyph changes in NSTextView.
    func render(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        let baseSize = PaneStyle.fontSize
        let typingAttributes = textView.typingAttributes
        let selectedRanges = textView.selectedRanges
        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.systemFont(ofSize: baseSize),
            .foregroundColor: PaneStyle.textNSColor,
            .paragraphStyle: paragraphStyle()
        ], range: NSRange(location: 0, length: storage.length))

        let elements = Markdown.parse(text)
        let headings = elements.compactMap { Heading(element: $0) }
        self.source = text
        self.elements = elements
        
        // First pass: apply all Markdown styling
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
                storage.addAttribute(.foregroundColor, value: PaneStyle.secondaryTextNSColor, range: element.range)
            case .tableCell(let alignment):
                let paragraph = paragraphStyle()
                paragraph.alignment = {
                    switch alignment {
                    case .left: .left
                    case .center: .center
                    case .right: .right
                    }
                }()
                storage.addAttribute(.paragraphStyle, value: paragraph, range: element.range)
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular), range: element.range)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: element.range)
            case .taskBody(let done):
                if done {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
                    storage.addAttribute(.foregroundColor, value: PaneStyle.secondaryTextNSColor, range: element.range)
                }
            case .tableHeader:
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseSize), range: element.range)
                storage.addAttribute(.backgroundColor, value: NSColor.tertiarySystemFill, range: element.range)
            case .strong:
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: contentFontSize(of: element, headings: headings, base: baseSize)), range: element.range)
            case .emphasis:
                storage.addAttribute(.font, value: italicFont(ofSize: contentFontSize(of: element, headings: headings, base: baseSize)), range: element.range)
            case .strongEmphasis:
                let bold = NSFont.boldSystemFont(ofSize: contentFontSize(of: element, headings: headings, base: baseSize))
                storage.addAttribute(.font, value: NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask), range: element.range)
            case .code:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular), range: element.range)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: element.range)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
            case .subscriptText:
                storage.addAttribute(.baselineOffset, value: -3, range: element.range)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize * 0.8), range: element.range)
            case .superscriptText:
                storage.addAttribute(.baselineOffset, value: 4, range: element.range)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize * 0.8), range: element.range)
            case .underline:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: element.range)
            case .lineBreak:
                break
            case .link(let urlString):
                if let url = URL(string: urlString) {
                    storage.addAttribute(.link, value: url, range: element.range)
                    storage.addAttribute(.foregroundColor, value: PaneStyle.accentNSColor, range: element.range)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
                    storage.addAttribute(.toolTip, value: urlString, range: element.range)
                }
            case .listItem(let level):
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(headIndent: CGFloat(16 * level), firstLineHeadIndent: 0), range: element.range)
            case .hidden, .escape:
                // Keep the source and its character indexes intact while
                // making syntax-only characters visually disappear. This is
                // deliberately unconditional: caret movement never changes
                // layout attributes and cannot trigger reflow artifacts.
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: element.range)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: element.range)
            }
        }
        
        // Cell styling is applied while walking the parser elements, so
        // re-apply header weight after cells have established their fonts.
        for element in elements {
            if case .tableHeader = element.kind {
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseSize), range: element.range)
                storage.addAttribute(.backgroundColor, value: NSColor.tertiarySystemFill, range: element.range)
            }
        }

        // Second pass: apply syntax highlighting to code blocks with language identifiers
        applyCodeHighlighting(to: storage, text: text, elements: elements, baseSize: baseSize)
        storage.endEditing()
        textView.typingAttributes = typingAttributes
        textView.selectedRanges = selectedRanges
    }

    /// Re-renders after a text edit. Selection-only changes are intentionally
    /// ignored because syntax attributes are stable across caret movement.
    func refresh(_ textView: NSTextView) {
        guard textView.string == source else {
            render(textView)
            return
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

    // MARK: Paragraph style

    private func paragraphStyle(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = PaneStyle.lineSpacing
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent
        return style
    }
    
    // MARK: Code Highlighting
    
    private func applyCodeHighlighting(to storage: NSTextStorage, text: String, elements: [Markdown.Element], baseSize: CGFloat) {
        var currentLanguage: String?
        
        for element in elements {
            switch element.kind {
            case .language:
                currentLanguage = (text as NSString).substring(with: element.range).trimmingCharacters(in: .whitespaces)
            case .codeBlock:
                if let language = currentLanguage, !language.isEmpty {
                    let range = element.range
                    // Use the actual code block content (not trimmed) for highlighting
                    let codeContent = (text as NSString).substring(with: range)
                    if !codeContent.isEmpty {
                        let highlighted = CodeHighlighter.highlight(code: codeContent, language: language, baseFont: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular))
                        // Apply attributes directly to the code block range
                        let fullRange = NSRange(location: 0, length: highlighted.length)
                        highlighted.enumerateAttributes(in: fullRange, options: []) { attrs, attrRange, _ in
                            let storageRange = NSRange(location: range.location + attrRange.location, length: attrRange.length)
                            if storageRange.location + storageRange.length <= storage.length {
                                storage.addAttributes(attrs, range: storageRange)
                            }
                        }
                    }
                }
                currentLanguage = nil
            default:
                break
            }
        }
    }
}

extension Markdown {
    /// Full render for callers without a persistent highlighter.
    ///
    /// Syntax-only markers remain hidden regardless of selection.
    static func highlight(_ textView: NSTextView) {
        MarkdownHighlighter().render(textView)
    }

    static func headingFontSize(level: Int, base: CGFloat) -> CGFloat {
        base + CGFloat(max(0, 12 - 2 * level))
    }
}
