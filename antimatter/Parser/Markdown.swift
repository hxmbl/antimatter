import AppKit
import Foundation

/// A deterministic Markdown parser covering the practical CommonMark/GFM
/// surface: ATX and setext headings, fenced code blocks (``` / ~~~) with
/// language tags, block quotes (nesting via repeated `>`), bullet and
/// ordered lists with indentation-based nesting, task list items, GFM
/// tables, thematic breaks, strong/emphasis/code/strikethrough spans,
/// inline links, images (rendered as links over their alt text), autolinks
/// and bare http(s) URLs.
///
/// `\` is the escape character everywhere, including inside code spans:
/// it makes the next character literal so it can never start, end, or
/// become markup. `\\` produces a literal backslash. Unmatched delimiters
/// render as plain text.
///
/// The parser reports element ranges only; the renderer decides appearance.
enum Markdown {
    struct Element: Equatable {
        nonisolated enum Kind: Equatable {
            case heading(level: Int)
            case quote(level: Int)
            case codeBlock
            case language
            /// A whole list-item line; the renderer indents by level.
            case listItem(level: Int)
            case taskMarker(done: Bool)
            case taskBody(done: Bool)
            case hr
            case tableRow
            case tableHeader
            case tableCell(alignment: TableAlignment)
            case tablePipe
            case strong
            case emphasis
            case strongEmphasis
            case code
            case strike
            case subscriptText
            case superscriptText
            case underline
            case highlight
            case lineBreak
            case link(String)
            /// Syntax characters the renderer displays dimmed.
            case hidden
            /// Punctuation kept visible but dimmed.
            case marker
            /// The backslash of an escaped character.
            case escape

            /// Elements that are syntax-only and rendered dimmed.
            nonisolated var isSyntaxMarker: Bool {
                switch self {
                case .hidden, .escape: true
                default: false
                }
            }
        }

        nonisolated enum TableAlignment: Equatable {
            case left
            case center
            case right
        }
        // `TableAlignment` is parsed for parity with GFM (the divider's
        // `:---:` / `---:` markers) but is display-inert in the pane:
        // NSTextView styles whole lines, so a column's glyphs cannot be
        // reflowed. The pane keeps the source's horizontal layout (monospaced
        // cells, author-padded columns). The value is kept so a future
        // real-table renderer can consume it without re-parsing.

        let kind: Kind
        let range: NSRange
    }

    /// Largest supported ATX heading level.
    nonisolated static let maxHeadingLevel = 6

    // MARK: - Entry point

    nonisolated static func parse(_ text: String) -> [Element] {
        var elements: [Element] = []
        let lines = lineRanges(text)
        var i = 0
        var fence: (char: Character, minLength: Int)?
        var prevWasParagraph = false

        while i < lines.count {
            let line = lines[i]

            if let open = fence {
                if let close = fenceClose(line, char: open.char, minLength: open.minLength, in: text) {
                    elements.append(.init(kind: .hidden, range: NSRange(close, in: text)))
                    fence = nil
                } else {
                    elements.append(.init(kind: .codeBlock, range: NSRange(line, in: text)))
                }
                i += 1
                continue
            }
            if let open = fenceOpen(line, in: text) {
                elements.append(.init(kind: .hidden, range: NSRange(open.ticks, in: text)))
                if let info = open.info {
                    elements.append(.init(kind: .language, range: NSRange(info, in: text)))
                }
                fence = (open.char, open.length)
                i += 1
                continue
            }

            if isBlank(line, in: text) {
                prevWasParagraph = false
                i += 1
                continue
            }

            let start = skipLeadingSpaces(line, limit: 3, in: text)

            if isThematicBreak(start..<line.upperBound, in: text),
               !(prevWasParagraph && isSetextUnderline(start..<line.upperBound, in: text)) {
                elements.append(.init(kind: .hr, range: NSRange(start..<line.upperBound, in: text)))
                prevWasParagraph = false
                i += 1
                continue
            }

            if parseHeading(text, in: line, from: start, into: &elements) {
                prevWasParagraph = false
                i += 1
                continue
            }

            if text[start] == ">" {
                while i < lines.count, let quote = quoteInfo(lines[i], in: text) {
                    appendQuote(quote, in: text, into: &elements)
                    i += 1
                }
                prevWasParagraph = false
                continue
            }

            if isTableRow(line, in: text), i + 1 < lines.count,
               isDividerRow(lines[i + 1], in: text) {
                let alignments = tableAlignments(lines[i + 1], in: text)
                emitTableRow(lines[i], header: true, alignments: alignments, in: text, into: &elements)
                elements.append(.init(kind: .tableRow, range: NSRange(lines[i + 1], in: text)))
                elements.append(.init(kind: .marker, range: NSRange(lines[i + 1], in: text)))
                i += 2
                while i < lines.count, isTableRow(lines[i], in: text) {
                    emitTableRow(lines[i], header: false, alignments: alignments, in: text, into: &elements)
                    i += 1
                }
                prevWasParagraph = false
                continue
            }

            if listItemInfo(skipLeadingSpaces(line, limit: 8, in: text), line, in: text) != nil {
                while i < lines.count {
                    let l = lines[i]
                    guard let it = listItemInfo(skipLeadingSpaces(l, limit: 8, in: text), l, in: text) else { break }
                    appendListItem(it, line: l, in: text, into: &elements)
                    i += 1
                    if i < lines.count, isBlank(lines[i], in: text) { break }
                }
                prevWasParagraph = false
                continue
            }

            var j = i
            while j < lines.count, !interruptsBlock(lines, at: j, in: text) {
                j += 1
            }
            if j == i { j = i + 1 }
            let underline = j < lines.count ? setextLevel(lines[j], in: text) : nil
            for k in i..<j {
                scanInline(text, in: lines[k], into: &elements)
                if k + 1 < j, hasHardBreak(at: lines[k], in: text) {
                    let newline = lines[k].upperBound..<lines[k + 1].lowerBound
                    elements.append(.init(kind: .lineBreak, range: NSRange(newline, in: text)))
                }
            }
            if let level = underline {
                elements.append(.init(kind: .heading(level: level), range: NSRange(lines[i].lowerBound..<lines[j].upperBound, in: text)))
                elements.append(.init(kind: .hidden, range: NSRange(lines[j], in: text)))
                i = j + 1
                prevWasParagraph = false
            } else {
                prevWasParagraph = j > i
                i = j
            }
        }
        // Sort by location, but keep insertion order for elements that share
        // one: the renderer relies on block styles (heading, strong) being
        // applied before their inner hidden markers, and Swift's sort does
        // not guarantee stability on its own.
        return elements.enumerated()
            .sorted { lhs, rhs in
                lhs.element.range.location == rhs.element.range.location
                    ? lhs.offset < rhs.offset
                    : lhs.element.range.location < rhs.element.range.location
            }
            .map(\.element)
    }

    // MARK: - Lines

    private nonisolated static func lineRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while true {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            ranges.append(start..<end)
            if end == text.endIndex { break }
            start = text.index(after: end)
        }
        return ranges
    }

    private nonisolated static func isBlank(_ line: Range<String.Index>, in text: String) -> Bool {
        line.isEmpty || text[line].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private nonisolated static func skipLeadingSpaces(_ line: Range<String.Index>, limit: Int, in text: String) -> String.Index {
        var i = line.lowerBound
        var count = 0
        while count < limit, i < line.upperBound, text[i] == " " {
            i = text.index(after: i)
            count += 1
        }
        return i
    }

    private nonisolated static func isBlockBreak(_ c: Character) -> Bool {
        c == " " || c == "\t"
    }

    private nonisolated static func contentStart(after markerEnd: String.Index, limit: String.Index, in text: String) -> String.Index {
        markerEnd < limit ? text.index(after: markerEnd) : markerEnd
    }

    // MARK: - Thematic breaks

    private nonisolated static func isThematicBreak(_ range: Range<String.Index>, in text: String) -> Bool {
        var marker: Character?
        var count = 0
        var i = range.lowerBound
        while i < range.upperBound {
            let c = text[i]
            if c == " " || c == "\t" {
                i = text.index(after: i)
                continue
            }
            if c != "-" && c != "*" && c != "_" { return false }
            if let marker {
                if c != marker { return false }
            } else {
                marker = c
            }
            count += 1
            i = text.index(after: i)
        }
        return count >= 3
    }

    // MARK: - Headings

    private nonisolated static func parseHeading(_ text: String, in line: Range<String.Index>, from start: String.Index, into out: inout [Element]) -> Bool {
        guard text[start] == "#" else { return false }
        var i = start
        var level = 0
        while i < line.upperBound, text[i] == "#" {
            level += 1
            i = text.index(after: i)
        }
        let followedByBreak = i == line.upperBound || isBlockBreak(text[i])
        guard (1...maxHeadingLevel).contains(level), followedByBreak else { return false }
        let content = contentStart(after: i, limit: line.upperBound, in: text)
        out.append(Element(kind: .heading(level: level), range: NSRange(start..<line.upperBound, in: text)))
        out.append(Element(kind: .hidden, range: NSRange(start..<i, in: text)))
        scanInline(text, in: content..<line.upperBound, into: &out)
        return true
    }

    private nonisolated static func setextLevel(_ line: Range<String.Index>, in text: String) -> Int? {
        let start = skipLeadingSpaces(line, limit: 3, in: text)
        guard start < line.upperBound else { return nil }
        let c = text[start]
        guard c == "=" || c == "-" else { return nil }
        var i = start
        while i < line.upperBound, text[i] == c {
            i = text.index(after: i)
        }
        while i < line.upperBound, text[i] == " " {
            i = text.index(after: i)
        }
        return i == line.upperBound ? (c == "=" ? 1 : 2) : nil
    }

    private nonisolated static func isSetextUnderline(_ range: Range<String.Index>, in text: String) -> Bool {
        setextLevel(range, in: text) != nil
    }

    // MARK: - Block quotes

    private nonisolated struct QuoteInfo {
        let arrows: Range<String.Index>
        let content: Range<String.Index>
        let level: Int
    }

    private nonisolated static func quoteInfo(_ line: Range<String.Index>, in text: String) -> QuoteInfo? {
        let start = skipLeadingSpaces(line, limit: 3, in: text)
        guard start < line.upperBound, text[start] == ">" else { return nil }
        var i = start
        var level = 0
        while i < line.upperBound, text[i] == ">" {
            level += 1
            i = text.index(after: i)
        }
        let content = contentStart(after: i, limit: line.upperBound, in: text)
        return QuoteInfo(arrows: start..<i, content: content..<line.upperBound, level: level)
    }

    private nonisolated static func appendQuote(_ quote: QuoteInfo, in text: String, into out: inout [Element]) {
        out.append(Element(kind: .quote(level: quote.level), range: NSRange(quote.content, in: text)))
        out.append(Element(kind: .hidden, range: NSRange(quote.arrows, in: text)))
        scanInline(text, in: quote.content, into: &out)
    }

    // MARK: - Fenced code

    private nonisolated struct FenceOpen {
        let char: Character
        let length: Int
        let ticks: Range<String.Index>
        let info: Range<String.Index>?
    }

    private nonisolated static func fenceOpen(_ line: Range<String.Index>, in text: String) -> FenceOpen? {
        let start = skipLeadingSpaces(line, limit: 3, in: text)
        guard start < line.upperBound else { return nil }
        let c = text[start]
        guard c == "`" || c == "~" else { return nil }
        var i = start
        var length = 0
        while i < line.upperBound, text[i] == c {
            length += 1
            i = text.index(after: i)
        }
        guard length >= 3 else { return nil }
        let rest = trimmed(i..<line.upperBound, in: text)
        return FenceOpen(char: c, length: length, ticks: start..<i, info: rest.isEmpty ? nil : rest)
    }

    private nonisolated static func fenceClose(_ line: Range<String.Index>, char: Character, minLength: Int, in text: String) -> Range<String.Index>? {
        let start = skipLeadingSpaces(line, limit: 3, in: text)
        guard start < line.upperBound, text[start] == char else { return nil }
        var i = start
        var length = 0
        while i < line.upperBound, text[i] == char {
            length += 1
            i = text.index(after: i)
        }
        guard length >= minLength, i == line.upperBound else { return nil }
        return start..<i
    }

    private nonisolated static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isBlockBreak(text[lower]) { lower = text.index(after: lower) }
        while upper > lower, isBlockBreak(text[text.index(before: upper)]) { upper = text.index(before: upper) }
        return lower..<upper
    }

    // MARK: - Lists

    private nonisolated struct ListItemInfo {
        let marker: Range<String.Index>
        let content: Range<String.Index>
        let level: Int
        let taskBracket: Range<String.Index>?
        let taskDone: Bool
    }

    private nonisolated static func listItemInfo(_ start: String.Index, _ line: Range<String.Index>, in text: String) -> ListItemInfo? {
        guard start < line.upperBound else { return nil }
        let first = text[start]
        var afterMarker: String.Index
        if first == "-" || first == "*" || first == "+" {
            afterMarker = text.index(after: start)
        } else if first.isNumber {
            var digitsEnd = start
            while digitsEnd < line.upperBound, text[digitsEnd].isNumber {
                digitsEnd = text.index(after: digitsEnd)
            }
            guard digitsEnd < line.upperBound, text[digitsEnd] == "." else { return nil }
            afterMarker = text.index(after: digitsEnd)
        } else {
            return nil
        }
        guard afterMarker < line.upperBound, isBlockBreak(text[afterMarker]) else { return nil }

        let indent = text.distance(from: line.lowerBound, to: start)
        let level = min(7, max(0, indent / 2))

        var body = contentStart(after: afterMarker, limit: line.upperBound, in: text)
        var taskBracket: Range<String.Index>?
        var taskDone = false
        if body < line.upperBound, text[body] == "[" {
            let close = text.index(after: body)
            if close < line.upperBound, let mark = text.index(close, offsetBy: 1, limitedBy: line.upperBound) {
                let inner = text[close]
                if text[mark] == "]" && (inner == "x" || inner == "X" || inner == " ") {
                    let afterBracket = text.index(after: mark)
                    if afterBracket == line.upperBound || isBlockBreak(text[afterBracket]) {
                        taskBracket = body..<afterBracket
                        taskDone = inner != " "
                        body = contentStart(after: afterBracket, limit: line.upperBound, in: text)
                        afterMarker = afterBracket
                    }
                }
            }
        }
        return ListItemInfo(marker: start..<afterMarker, content: body..<line.upperBound, level: level, taskBracket: taskBracket, taskDone: taskDone)
    }

    private nonisolated static func appendListItem(_ item: ListItemInfo, line: Range<String.Index>, in text: String, into out: inout [Element]) {
        out.append(Element(kind: .listItem(level: item.level), range: NSRange(line, in: text)))
        out.append(Element(kind: .marker, range: NSRange(item.marker, in: text)))
        if let bracket = item.taskBracket {
            out.append(Element(kind: .taskMarker(done: item.taskDone), range: NSRange(bracket, in: text)))
            out.append(Element(kind: .taskBody(done: item.taskDone), range: NSRange(item.content, in: text)))
            scanInline(text, in: item.content, into: &out)
        } else {
            scanInline(text, in: item.content, into: &out)
        }
    }

    // MARK: - Tables

    private nonisolated static func isTableRow(_ line: Range<String.Index>, in text: String) -> Bool {
        !line.isEmpty && text[line].contains("|")
    }

    private nonisolated static func isDividerRow(_ line: Range<String.Index>, in text: String) -> Bool {
        let cells = tableCells(line, in: text)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var i = cell.lowerBound
            if text[i] == ":" { i = text.index(after: i) }
            var dashes = 0
            while i < cell.upperBound, text[i] == "-" {
                dashes += 1
                i = text.index(after: i)
            }
            if i < cell.upperBound, text[i] == ":" { i = text.index(after: i) }
            return i == cell.upperBound && dashes >= 1
        }
    }

    private nonisolated static func tableCells(_ line: Range<String.Index>, in text: String) -> [Range<String.Index>] {
        var cells: [Range<String.Index>] = []
        var cursor = line.lowerBound
        if cursor < line.upperBound, text[cursor] == "|" {
            cursor = text.index(after: cursor)
        }
        while cursor < line.upperBound {
            var pipe: String.Index?
            var i = cursor
            while i < line.upperBound {
                if text[i] == "\\" {
                    i = advanceEscaped(i, limit: line.upperBound, in: text)
                    continue
                }
                if text[i] == "|" {
                    pipe = i
                    break
                }
                i = text.index(after: i)
            }
            guard let found = pipe else { break }
            cells.append(trimmed(cursor..<found, in: text))
            cursor = text.index(after: found)
        }
        var end = line.upperBound
        if end > cursor, text[text.index(before: end)] == "|" {
            end = text.index(before: end)
        }
        if cursor <= end {
            cells.append(trimmed(cursor..<end, in: text))
        }
        return cells.filter { !$0.isEmpty }
    }

    private nonisolated static func tableAlignments(_ line: Range<String.Index>, in text: String) -> [Element.TableAlignment] {
        tableCells(line, in: text).map { cell in
            let trimmedCell = trimmed(cell, in: text)
            let starts = trimmedCell.lowerBound < trimmedCell.upperBound && text[trimmedCell.lowerBound] == ":"
            let ends = trimmedCell.lowerBound < trimmedCell.upperBound && text[text.index(before: trimmedCell.upperBound)] == ":"
            if starts && ends { return .center }
            if ends { return .right }
            return .left
        }
    }

    private nonisolated static func emitTableRow(
        _ line: Range<String.Index>,
        header: Bool,
        alignments: [Element.TableAlignment],
        in text: String,
        into out: inout [Element]
    ) {
        if header {
            out.append(Element(kind: .tableRow, range: NSRange(line, in: text)))
            out.append(Element(kind: .tableHeader, range: NSRange(line, in: text)))
        } else {
            out.append(Element(kind: .tableRow, range: NSRange(line, in: text)))
        }
        var i = line.lowerBound
        while i < line.upperBound {
            if text[i] == "\\" {
                i = text.index(after: i)
                if i < line.upperBound { i = text.index(after: i) }
                continue
            }
            if text[i] == "|" {
                out.append(Element(kind: .tablePipe, range: NSRange(i..<text.index(after: i), in: text)))
            }
            i = text.index(after: i)
        }
        for (index, cell) in tableCells(line, in: text).enumerated() {
            let alignment = index < alignments.count ? alignments[index] : .left
            out.append(Element(kind: .tableCell(alignment: alignment), range: NSRange(cell, in: text)))
            scanInline(text, in: cell, into: &out)
        }
    }

    // MARK: - Inline scanning

    private nonisolated static let autolinkSchemes = ["https://", "http://", "mailto:"]

    private nonisolated static func interruptsBlock(_ lines: [Range<String.Index>], at index: Int, in text: String) -> Bool {
        let line = lines[index]
        let start = skipLeadingSpaces(line, limit: 3, in: text)
        guard start < line.upperBound else { return true }
        switch text[start] {
        case "#", ">":
            return true
        case "`", "~":
            return fenceOpen(line, in: text) != nil
        case "|":
            return index + 1 < lines.count && isTableRow(line, in: text) && isDividerRow(lines[index + 1], in: text)
        case "-", "*", "+":
            let next = text.index(after: start)
            if next < line.upperBound, isBlockBreak(text[next]) { return true }
            return isThematicBreak(start..<line.upperBound, in: text)
        default:
            if setextLevel(line, in: text) != nil { return true }
            if text[start].isNumber {
                var digitsEnd = start
                while digitsEnd < line.upperBound, text[digitsEnd].isNumber {
                    digitsEnd = text.index(after: digitsEnd)
                }
                if digitsEnd < line.upperBound, text[digitsEnd] == "." {
                    let afterDot = text.index(after: digitsEnd)
                    if afterDot < line.upperBound, isBlockBreak(text[afterDot]) { return true }
                }
                return false
            }
            return isThematicBreak(start..<line.upperBound, in: text)
        }
    }

    /// Allocation-free `hasPrefix` for a sub-range; slicing a substring per
    /// candidate character dominated parse time on plain-text documents.
    private nonisolated static func startsWith(_ text: String, _ prefix: String, at start: String.Index, limit: String.Index) -> Bool {
        var i = start
        for character in prefix {
            guard i < limit, text[i] == character else { return false }
            text.formIndex(after: &i)
        }
        return true
    }

    private nonisolated static func scanInline(_ text: String, in range: Range<String.Index>, into out: inout [Element]) {
        var i = range.lowerBound
        while i < range.upperBound {
            switch text[i] {
            case "\\":
                let next = text.index(after: i)
                out.append(Element(kind: .escape, range: NSRange(i..<next, in: text)))
                i = next < range.upperBound ? text.index(after: next) : next
            case "`":
                let ticks = codeTickLength(i, range: range, text: text)
                if let end = readSpan("`", count: ticks, from: i, limit: range.upperBound, kind: .code, inclusive: true, text: text, into: &out) {
                    i = end
                } else {
                    i = text.index(i, offsetBy: ticks, limitedBy: range.upperBound) ?? range.upperBound
                }

            case "~":
                let next = text.index(after: i)
                let kind: Element.Kind = next < range.upperBound && text[next] == "~" ? .strike : .subscriptText
                let count = kind == .strike ? 2 : 1
                if let end = readSpan("~", count: count, from: i, limit: range.upperBound, kind: kind, inclusive: false, text: text, into: &out) {
                    i = end
                } else {
                    i = next
                }
            case "*":
                let next = text.index(after: i)
                let third = next < range.upperBound ? text.index(after: next) : next
                if next < range.upperBound, third < range.upperBound,
                   text[next] == "*",
                   text[third] == "*" {
                    if let end = readSpan("*", count: 3, from: i, limit: range.upperBound, kind: .strongEmphasis, inclusive: false, text: text, into: &out) {
                        i = end
                        continue
                    }
                }

                if next < range.upperBound, text[next] == "*" {
                    if let end = readSpan("*", count: 2, from: i, limit: range.upperBound, kind: .strong, inclusive: false, text: text, into: &out) {
                        i = end
                        continue
                    }
                }
                if let end = readSpan("*", count: 1, from: i, limit: range.upperBound, kind: .emphasis, inclusive: false, text: text, into: &out) {
                    i = end
                } else {
                    i = next
                }
            case "_":
                let next = text.index(after: i)
                let third = next < range.upperBound ? text.index(after: next) : next
                if next < range.upperBound, third < range.upperBound,
                   text[next] == "_",
                   text[third] == "_" {
                    if let end = readSpan("_", count: 3, from: i, limit: range.upperBound, kind: .strongEmphasis, inclusive: false, text: text, into: &out) {
                        i = end
                        continue
                    }
                }
                if next < range.upperBound, text[next] == "_" {
                    if let end = readSpan("_", count: 2, from: i, limit: range.upperBound, kind: .strong, inclusive: false, text: text, into: &out) {
                        i = end
                    } else { i = next }
                } else if let end = readSpan("_", count: 1, from: i, limit: range.upperBound, kind: .emphasis, inclusive: false, text: text, into: &out) {
                    i = end
                } else {
                    i = next
                }
            case "<":
                if let end = readHTMLSpan(text, from: i, limit: range.upperBound, into: &out) {
                    i = end
                } else if let end = readAutolink(text, from: i, limit: range.upperBound, into: &out) {
                    i = end
                } else {
                    i = text.index(after: i)
                }
            case "=":
                let next = text.index(after: i)
                if next < range.upperBound, text[next] == "=",
                   let end = readSpan("=", count: 2, from: i, limit: range.upperBound, kind: .highlight, inclusive: false, text: text, into: &out) {
                    i = end
                } else {
                    i = next
                }
            case "^":
                if let end = readSpan("^", count: 1, from: i, limit: range.upperBound, kind: .superscriptText, inclusive: false, text: text, into: &out) {
                    i = end
                } else {
                    i = text.index(after: i)
                }
            case "!":
                if let end = readLink(text, from: text.index(after: i), limit: range.upperBound, imagePrefix: i, into: &out) {
                    i = end
                } else {
                    i = text.index(after: i)
                }
            case "[":
                if let end = readLink(text, from: i, limit: range.upperBound, imagePrefix: nil, into: &out) {
                    i = end
                } else {
                    i = text.index(after: i)
                }
            default:
                if text[i] == "h" || text[i] == "m" || text[i] == "w",
                   let end = readBareURL(text, from: i, limit: range.upperBound, into: &out) {
                    i = end
                } else {
                    i = text.index(after: i)
                }

            }
        }
    }

    private nonisolated static func hasHardBreak(at line: Range<String.Index>, in text: String) -> Bool {
        guard line.lowerBound < line.upperBound else { return false }
        var end = line.upperBound
        var spaces = 0
        while end > line.lowerBound, text[text.index(before: end)] == " " {
            spaces += 1
            end = text.index(before: end)
        }
        if spaces >= 2 { return true }
        return end > line.lowerBound && text[text.index(before: end)] == "\\"
    }

    private nonisolated static func readHTMLSpan(
        _ text: String,
        from start: String.Index,
        limit: String.Index,
        into out: inout [Element]
    ) -> String.Index? {
        let tags: [(String, String, Element.Kind)] = [
            ("<sub>", "</sub>", .subscriptText),
            ("<sup>", "</sup>", .superscriptText),
            ("<super>", "</super>", .superscriptText),
            ("<u>", "</u>", .underline)
        ]
        for (open, close, kind) in tags where startsWith(text, open, at: start, limit: limit) {
            let contentStart = text.index(start, offsetBy: open.count)
            guard let closeStart = text.range(of: close, range: contentStart..<limit)?.lowerBound,
                  closeStart > contentStart else { continue }
            let end = text.index(closeStart, offsetBy: close.count)
            out.append(Element(kind: kind, range: NSRange(contentStart..<closeStart, in: text)))
            appendHidden(start..<contentStart, text: text, into: &out)
            appendHidden(closeStart..<end, text: text, into: &out)
            scanInline(text, in: contentStart..<closeStart, into: &out)
            return end
        }
        return nil
    }

    private nonisolated static func codeTickLength(_ i: String.Index, range: Range<String.Index>, text: String) -> Int {
        var length = 0
        var j = i
        while j < range.upperBound, text[j] == "`" {
            length += 1
            j = text.index(after: j)
        }
        return max(1, length)
    }

    /// Reads a delimited span starting at `start`, returning the index just
    /// past the closing delimiter, or `nil` when no non-empty span closes.
    /// When `inclusive` is set the styled range also covers both delimiters,
    /// which keeps background fills continuous around syntax markers.
    private nonisolated static func readSpan(
        _ delimiter: Character,
        count required: Int,
        from start: String.Index,
        limit: String.Index,
        kind: Element.Kind,
        inclusive: Bool,
        text: String,
        into out: inout [Element]
    ) -> String.Index? {
        guard let openEnd = text.index(start, offsetBy: required, limitedBy: limit) else { return nil }
        guard let close = findDelimiter(delimiter, count: required, from: openEnd, limit: limit, in: text), close > openEnd else { return nil }
        let closeEnd = text.index(close, offsetBy: required)
        if inclusive {
            out.append(Element(kind: kind, range: NSRange(start..<closeEnd, in: text)))
        } else {
            out.append(Element(kind: kind, range: NSRange(openEnd..<close, in: text)))
        }
        appendHidden(start..<openEnd, text: text, into: &out)
        appendHidden(close..<closeEnd, text: text, into: &out)
        if kind == .strong || kind == .emphasis || kind == .strongEmphasis || kind == .strike {
            scanInline(text, in: openEnd..<close, into: &out)
        }
        return closeEnd
    }

    /// Finds the first unescaped run of exactly `required` delimiter characters.
    private nonisolated static func findDelimiter(
        _ delimiter: Character,
        count required: Int,
        from start: String.Index,
        limit: String.Index,
        in text: String
    ) -> String.Index? {
        var i = start
        while i < limit {
            if text[i] == "\\" {
                i = advanceEscaped(i, limit: limit, in: text)
                continue
            }
            if text[i] == delimiter {
                var runEnd = i
                var runLength = 0
                while runEnd < limit, text[runEnd] == delimiter, runLength < required {
                    runEnd = text.index(after: runEnd)
                    runLength += 1
                }
                if runLength == required { return i }
                i = runEnd
                continue
            }
            i = text.index(after: i)
        }
        return nil
    }

    private nonisolated static func advanceEscaped(_ backslash: String.Index, limit: String.Index, in text: String) -> String.Index {
        let next = text.index(after: backslash)
        return next < limit ? text.index(after: next) : next
    }

    private nonisolated static func appendHidden(_ subRange: Range<String.Index>, text: String, into out: inout [Element]) {
        guard !subRange.isEmpty else { return }
        out.append(Element(kind: .hidden, range: NSRange(subRange, in: text)))
    }

    // MARK: Links, images, autolinks

    private nonisolated static func readLink(
        _ text: String,
        from start: String.Index,
        limit: String.Index,
        imagePrefix: String.Index?,
        into out: inout [Element]
    ) -> String.Index? {
        guard start < limit, text[start] == "[" else { return nil }
        guard let labelEnd = findDelimiter("]", count: 1, from: text.index(after: start), limit: limit, in: text),
              labelEnd > text.index(after: start),
              text.index(after: labelEnd) < limit,
              text[text.index(after: labelEnd)] == "("
        else { return nil }
        let parenStart = text.index(after: labelEnd)
        guard let urlEnd = findDelimiter(")", count: 1, from: text.index(after: parenStart), limit: limit, in: text),
              urlEnd > text.index(after: parenStart)
        else { return nil }
        let closeEnd = text.index(after: urlEnd)
        let urlString = Self.stripTrackingParameters(from: String(text[text.index(after: parenStart)..<urlEnd]))
        guard URL(string: urlString) != nil else { return nil }
        if let bang = imagePrefix {
            out.append(Element(kind: .hidden, range: NSRange(bang..<start, in: text)))
        }
        appendHidden(start..<text.index(after: start), text: text, into: &out)
        out.append(Element(kind: .link(urlString), range: NSRange(text.index(after: start)..<labelEnd, in: text)))
        appendHidden(labelEnd..<closeEnd, text: text, into: &out)
        return closeEnd
    }

    private nonisolated static func readAutolink(_ text: String, from start: String.Index, limit: String.Index, into out: inout [Element]) -> String.Index? {
        guard start < limit, text[start] == "<" else { return nil }
        let innerStart = text.index(after: start)
        guard innerStart < limit else { return nil }
        var matched = false
        for scheme in autolinkSchemes where startsWith(text, scheme, at: innerStart, limit: limit) {
            matched = true
            break
        }
        guard matched, let gt = findDelimiter(">", count: 1, from: innerStart, limit: limit, in: text), gt > innerStart else { return nil }
        let closeEnd = text.index(after: gt)
        let urlString = Self.stripTrackingParameters(from: String(text[innerStart..<gt]))
        guard URL(string: urlString) != nil else { return nil }
        appendHidden(start..<innerStart, text: text, into: &out)
        out.append(Element(kind: .link(urlString), range: NSRange(innerStart..<gt, in: text)))
        appendHidden(gt..<closeEnd, text: text, into: &out)
        return closeEnd
    }

    /// Recognises bare URLs in running text: `https://`/`http://`/`mailto:`
    /// addresses and schemeless `www.` hosts (which link to their https
    /// form). Trailing punctuation stays outside the link.
    private nonisolated static func readBareURL(_ text: String, from start: String.Index, limit: String.Index, into out: inout [Element]) -> String.Index? {
        var hrefPrefix = ""
        if startsWith(text, "https://", at: start, limit: limit) || startsWith(text, "http://", at: start, limit: limit) {
            // href is the displayed text itself.
        } else if startsWith(text, "mailto:", at: start, limit: limit) {
            // href is the displayed text itself.
        } else if startsWith(text, "www.", at: start, limit: limit) {
            hrefPrefix = "https://"
        } else {
            return nil
        }

        var end = start
        while end < limit {
            let c = text[end]
            if isBlockBreak(c) || c == "<" || c == ">" || c == "(" || c == ")" || c == "\"" || c == "`" { break }
            end = text.index(after: end)
        }
        while end > start, ".,!?:;'".contains(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        guard end > start else { return nil }
        // A schemeless host needs a real domain, not a stray "www." — GFM
        // requires at least one more dot before text linkifies.
        if !hrefPrefix.isEmpty {
            guard text.distance(from: start, to: end) > 4 else { return nil }
            let host = text[text.index(start, offsetBy: 4)..<end]
            guard host.contains("."), host.count > 1 else { return nil }
        }
        let urlString = Self.stripTrackingParameters(from: hrefPrefix + String(text[start..<end]))
        guard URL(string: urlString) != nil else { return nil }
        out.append(Element(kind: .link(urlString), range: NSRange(start..<end, in: text)))
        return end
    }

    // MARK: URL hygiene

    /// A URL "shrunk" without a network call: tracking parameters are dropped
    /// so the stored and displayed address is the clean canonical one. Used by
    /// every link form (inline, autolink, bare) so pasting a campaign URL
    /// never litters the note with `?utm_…`.
    nonisolated static func stripTrackingParameters(from urlString: String) -> String {
        guard let url = URLComponents(string: urlString),
              let items = url.queryItems, !items.isEmpty else { return urlString }
        let kept = items.filter { !Self.trackingParameters.contains($0.name.lowercased()) }
        guard kept.count != items.count else { return urlString }
        var cleaned = url
        cleaned.queryItems = kept.isEmpty ? nil : kept
        return cleaned.string ?? urlString
    }

    /// Parameter names that exist only to track a referral, not to address a
    /// resource. Common across every major campaign (UTM, social, ad, mail).
    private nonisolated static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_cid", "utm_reader", "utm_referrer", "utm_name", "utm_pubreferrer",
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "twclid", "yclid",
        "igshid", "sc_campaign", "sc_channel", "sc_content", "sc_medium", "sc_outcome",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "vero_conv", "vero_id", "li_fat_id",
        "s_cid", "spm", "spref", "si",
    ]
}
