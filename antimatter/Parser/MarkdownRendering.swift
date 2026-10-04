import AppKit
import Foundation


/// Renders Markdown styling to an NSTextView. Selection changes never alter
/// the document's glyph attributes, so caret movement cannot reflow glyphs.
final class MarkdownHighlighter {
    private var source = ""
    /// The appearance the last render was done for. `refresh` skips work when the
    /// text has not changed, but code-block colours are picked from the live
    /// `NSApp.effectiveAppearance` — so a light/dark switch whose theme happens to
    /// share the same text colour left every code colour in the old palette until
    /// the next keystroke.
    private var renderedForDarkAppearance = false

    /// Appearance resolved once per render rather than once per token.
    static var isDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Re-parses and re-applies Markdown styling. The raw string stays untouched.
    func render(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = textView.string
        renderedForDarkAppearance = Self.isDarkAppearance
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

        // Table cells need monospaced face for column alignment.
        let cellRanges = elements.compactMap { element -> NSRange? in
            guard case .tableCell = element.kind else { return nil }
            return element.range
        }

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
            case .marker:
                // A lone `-`/`*`/`+` at content start is a Notion-style
                // bullet: lean on it in the accent color so list items read
                // as bullets rather than dim syntax. Divider rows (which
                // cover a whole `|---|` line) and numbered markers keep the
                // quiet secondary tint.
                if isListBulletMarker(at: element.range.location, in: text) {
                    storage.addAttribute(.foregroundColor, value: PaneStyle.accentNSColor.withAlphaComponent(0.85), range: element.range)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: baseSize, weight: .semibold), range: element.range)
                } else {
                    storage.addAttribute(.foregroundColor, value: PaneStyle.secondaryTextNSColor, range: element.range)
                }
            case .language, .hr, .tablePipe, .taskMarker:
                storage.addAttribute(.foregroundColor, value: PaneStyle.secondaryTextNSColor, range: element.range)
            case .tableRow:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular), range: element.range)
                // A full-row band behind every cell (and the pipes between)
                // makes the table read as a contiguous grid rather than
                // disconnected per-cell islands.
                storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: element.range)
            case .tableCell:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular), range: element.range)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: element.range)
                // `alignment` is parsed and deliberately not applied: a table row
                // is a *single paragraph* to AppKit, so per-cell alignment is not
                // expressible — setting it over one cell's range would move the
                // whole line, and the last cell written would win. Left unused
                // rather than faked; the value is kept for a future renderer that
                // can lay cells out as separate text blocks.
            case .taskBody(let done):
                if done {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: element.range)
                    storage.addAttribute(.foregroundColor, value: PaneStyle.secondaryTextNSColor, range: element.range)
                }
            case .tableHeader:
                // Font is *not* set here. A wholesale `.font` over the whole
                // header line re-styled two things it should not have: the syntax
                // markers already shrunk to 1 pt and made `.clear` by the
                // `.hidden` branch (which put them back to full width, so a `**`
                // in a header occupied two monospaced columns and broke the very
                // alignment the monospaced face exists for), and any italic or
                // inline code inside the header, which was silently flattened.
                // Header weight is added by `boldenHeader`, which adds the bold
                // trait to whatever font each run already has.
                storage.addAttribute(.backgroundColor, value: NSColor.tertiarySystemFill, range: element.range)
            case .strong:
                storage.addAttribute(.font, value: inlineFont(for: element, cells: cellRanges, headings: headings, base: baseSize, trait: .bold), range: element.range)
            case .emphasis:
                storage.addAttribute(.font, value: inlineFont(for: element, cells: cellRanges, headings: headings, base: baseSize, trait: .italic), range: element.range)
            case .strongEmphasis:
                storage.addAttribute(.font, value: inlineFont(for: element, cells: cellRanges, headings: headings, base: baseSize, trait: .boldItalic), range: element.range)
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
        
        // Cell styling is applied while walking the parser elements, so header
        // weight goes on afterwards — by *adding* the bold trait to each run's
        // existing font rather than replacing it, which is what preserves italic
        // and inline code inside a header cell.
        for element in elements {
            if case .tableHeader = element.kind {
                boldenHeader(in: storage, range: element.range)
            }
        }

        // Keep substitution source editable and index-stable, but visually
        // quiet so its evaluated ghost can sit beside the definition.
        for span in ExpressionEvaluator.interpolationSpans(in: text) {
            storage.addAttribute(.foregroundColor, value: PaneStyle.secondaryTextNSColor, range: span.range)
        }

        // Second pass: apply syntax highlighting to code blocks with language identifiers
        applyCodeHighlighting(to: storage, text: text, elements: elements, baseSize: baseSize)
        storage.endEditing()
        // Resolve the new line fragments before restoring the selection. Without
        // this, AppKit can draw one frame using the pre-render line geometry,
        // making the native insertion point briefly appear on the line above
        // while the full-document attributes settle.
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        textView.typingAttributes = typingAttributes
        textView.selectedRanges = selectedRanges
    }

    /// Re-renders after a text edit. Selection-only changes are intentionally
    /// ignored because syntax attributes are stable across caret movement.
    func refresh(_ textView: NSTextView) {
        // Unchanged text is normally nothing to do — but code-block colours come
        // from the live appearance, so a light/dark switch has to force a
        // re-render even when the text is untouched.
        guard textView.string != source || Self.isDarkAppearance != renderedForDarkAppearance else {
            return
        }
        render(textView)
    }


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

    /// Adds bold to a table header without disturbing anything else about it.
    ///
    /// Runs already collapsed to the hidden-marker font (1 pt, `.clear`) are
    /// skipped: they are syntax, not content, and giving them a real weight put
    /// their width back and pushed the columns out of alignment.
    private func boldenHeader(in storage: NSTextStorage, range: NSRange) {
        let hiddenFont = NSFont.systemFont(ofSize: 1)
        storage.enumerateAttribute(.font, in: range, options: []) { value, run, _ in
            guard let font = value as? NSFont else { return }
            guard font.pointSize > 1.01 else { return }
            storage.addAttribute(
                .font,
                value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                range: run)
        }
        _ = hiddenFont
    }

    private enum InlineTrait {
        case bold
        case italic
        case boldItalic
    }

    private static func monospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func inlineFont(
        for element: Markdown.Element,
        cells: [NSRange],
        headings: [Heading],
        base: CGFloat,
        trait: InlineTrait
    ) -> NSFont {
        let size = contentFontSize(of: element, headings: headings, base: base)
        let inTableCell = cells.contains { NSLocationInRange(element.range.location, $0) }
        let font: NSFont

        if inTableCell {
            let weight: NSFont.Weight = trait == .bold || trait == .boldItalic ? .bold : .regular
            font = Self.monospacedFont(ofSize: size, weight: weight)
        } else {
            switch trait {
            case .bold:
                font = NSFont.boldSystemFont(ofSize: size)
            case .italic:
                font = italicFont(ofSize: size)
            case .boldItalic:
                let bold = NSFont.boldSystemFont(ofSize: size)
                font = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
            }
        }

        guard trait == .italic || trait == .boldItalic, inTableCell else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }


    /// Is this element range a list bullet marker (`-`/`*`/`+` prefixed only
    /// by indentation on its line)? Pipes and numbered markers return false.
    private func isListBulletMarker(at location: Int, in text: String) -> Bool {
        let ns = text as NSString
        guard location < ns.length else { return false }
        let character = ns.character(at: location)
        guard character == unichar("-") || character == unichar("*") || character == unichar("+") else { return false }
        var index = location
        while index > 0 {
            switch ns.character(at: index - 1) {
            case unichar("\n"):
                return true
            case unichar(" "), unichar("\t"):
                index -= 1
            default:
                return false
            }
        }
        return true
    }

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
    
    
    /// Highlights each fenced block in one pass.
    ///
    /// `Markdown.parse` emits one `.codeBlock` element *per line*, and feeding
    /// those to the lexer one at a time reset its state every line — so a
    /// multi-line block comment or a Python triple-quoted string only coloured
    /// its first line, and the closing `*/` was tokenised as two operators,
    /// which made the comment look like it broke open mid-way. Consecutive code
    /// lines are therefore merged back into a single contiguous span (newlines
    /// included) and handed over as one string, which is the only way lexer
    /// state can survive a line boundary.
    private func applyCodeHighlighting(to storage: NSTextStorage, text: String, elements: [Markdown.Element], baseSize: CGFloat) {
        let ns = text as NSString
        var currentLanguage: String?
        var pendingStart: Int?
        var pendingEnd = 0

        func flush() {
            defer { pendingStart = nil }
            guard let start = pendingStart, let language = currentLanguage, !language.isEmpty else { return }
            let range = NSRange(location: start, length: pendingEnd - start)
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            let code = ns.substring(with: range)
            guard !code.isEmpty else { return }
            let highlighted = CodeHighlighter.highlight(
                code: code,
                language: language,
                baseFont: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular))
            highlighted.enumerateAttributes(
                in: NSRange(location: 0, length: highlighted.length), options: []
            ) { attrs, attrRange, _ in
                let storageRange = NSRange(location: start + attrRange.location, length: attrRange.length)
                guard storageRange.location + storageRange.length <= storage.length else { return }
                storage.addAttributes(attrs, range: storageRange)
            }
        }

        for element in elements {
            switch element.kind {
            case .language:
                flush()
                currentLanguage = ns.substring(with: element.range)
                    .trimmingCharacters(in: .whitespaces)
            case .codeBlock:
                // Elements arrive location-sorted, so a run of code lines is
                // simply consecutive `.codeBlock` cases.
                if pendingStart == nil { pendingStart = element.range.location }
                pendingEnd = NSMaxRange(element.range)
            case .hidden:
                // The closing fence ends the block.
                if pendingStart != nil { flush() }
                currentLanguage = nil
            default:
                if pendingStart != nil { flush() }
                break
            }
        }
        flush()
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
