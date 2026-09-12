import AppKit
import Foundation

// MARK: - Code syntax highlighting

/// Lightweight syntax highlighter for code blocks.
enum CodeHighlighter {
    // MARK: Color palette

    /// Colorful, Xcode/GitHub-inspired palette. Adapts to light/dark appearance.
    private static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static var keywordColor: NSColor {
        isDark ? NSColor(hex: "#FF7AB2") : NSColor(hex: "#AF00DB")
    }
    private static var stringColor: NSColor {
        isDark ? NSColor(hex: "#C3E88D") : NSColor(hex: "#C41A16")
    }
    private static var commentColor: NSColor {
        isDark ? NSColor(hex: "#7A7F98") : NSColor(hex: "#6E7781")
    }
    private static var numberColor: NSColor {
        isDark ? NSColor(hex: "#F78C6C") : NSColor(hex: "#098658")
    }
    private static var typeColor: NSColor {
        isDark ? NSColor(hex: "#82AAFF") : NSColor(hex: "#0550AE")
    }
    private static var literalColor: NSColor {
        isDark ? NSColor(hex: "#C792EA") : NSColor(hex: "#CF222E")
    }
    private static var functionColor: NSColor {
        isDark ? NSColor(hex: "#FFCB6B") : NSColor(hex: "#8250DF")
    }
    private static var operatorColor: NSColor {
        isDark ? NSColor(hex: "#FF6B6B") : NSColor(hex: "#D63031")
    }
    private static var preprocessorColor: NSColor {
        isDark ? NSColor(hex: "#00B894") : NSColor(hex: "#00897B")
    }
    private static var attributeColor: NSColor {
        isDark ? NSColor(hex: "#00CEC9") : NSColor(hex: "#0097A7")
    }
    private static var htmlTagColor: NSColor {
        isDark ? NSColor(hex: "#A29BFE") : NSColor(hex: "#6C5CE7")
    }
    private static var cssPropertyColor: NSColor {
        isDark ? NSColor(hex: "#FDCB6E") : NSColor(hex: "#E1705A")
    }
    private static var markdownColor: NSColor {
        isDark ? NSColor(hex: "#74B9FF") : NSColor(hex: "#0984E3")
    }

    // MARK: Token classification

    private static let literals: Set<String> = [
        "true", "false", "nil", "null", "none", "NULL", "Nil", "None",
        "yes", "no", "on", "off", "YES", "NO"
    ]

    private static let typeKeywords: Set<String> = [
        "int", "int8", "int16", "int32", "int64",
        "uint", "uint8", "uint16", "uint32", "uint64",
        "float", "float32", "float64", "double", "decimal", "number",
        "string", "char", "bool", "boolean", "byte", "rune",
        "void", "any", "object", "array", "list", "dict", "map", "set",
        "tuple", "char8_t", "char16_t", "char32_t", "wchar_t",
        "size_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t",
        "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "i8", "i16", "i32", "i64", "i128", "isize",
        "u8", "u16", "u32", "u64", "u128", "usize",
        "f32", "f64", "str", "string", "vec", "hashmap", "hashset",
        "date", "time", "datetime", "timestamp", "text", "blob",
        "integer", "bigint", "smallint", "numeric", "real",
        // Swift / ObjC bridged
        "int", "string", "double", "float", "bool", "array", "dictionary",
        "optional", "result", "error", "instancetype",
    ]

    // MARK: Highlight entry point

    static func highlight(code: String, language: String?, baseFont: NSFont) -> NSAttributedString {
        let highlighted = NSMutableAttributedString(string: code)
        highlighted.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: highlighted.length))

        guard let language = language?.lowercased(),
              let def = SyntaxLanguageRegistry.definition(for: language) else {
            return highlighted
        }

        let nsCode = code as NSString
        let length = nsCode.length
        guard length > 0 else { return highlighted }

        let fullRange = NSRange(location: 0, length: length)
        highlighted.addAttribute(.foregroundColor, value: PaneStyle.textNSColor, range: fullRange)

        var i = 0
        var inBlockComment = false

        while i < length {
            let char = nsCode.character(at: i)

            if inBlockComment {
                if let end = def.blockCommentEnd,
                   let endRange = SyntaxScanner.findString(end, in: nsCode, from: i) {
                    highlighted.addAttribute(.foregroundColor, value: commentColor, range: NSRange(location: i, length: endRange.location - i + endRange.length))
                    i = endRange.location + endRange.length
                    inBlockComment = false
                } else {
                    highlighted.addAttribute(.foregroundColor, value: commentColor, range: NSRange(location: i, length: length - i))
                    break
                }
                continue
            }

            if let start = def.blockCommentStart,
               char == (start.utf16.first ?? 0),
               SyntaxScanner.findString(start, in: nsCode, from: i)?.location == i {
                if let end = def.blockCommentEnd,
                   let endRange = SyntaxScanner.findString(end, in: nsCode, from: i + start.count) {
                    let endLoc = endRange.location + endRange.length
                    highlighted.addAttribute(.foregroundColor, value: commentColor, range: NSRange(location: i, length: endLoc - i))
                    i = endLoc
                } else {
                    highlighted.addAttribute(.foregroundColor, value: commentColor, range: NSRange(location: i, length: length - i))
                    break
                }
                continue
            }

            // Single-line comment
            if !def.commentPrefix.isEmpty,
               SyntaxScanner.findString(def.commentPrefix, in: nsCode, from: i)?.location == i {
                // Find end of line
                let lineEnd = nsCode.range(of: "\n", range: NSRange(location: i, length: length - i))
                let commentEnd = lineEnd.location == NSNotFound ? length : lineEnd.location
                highlighted.addAttribute(.foregroundColor, value: commentColor, range: NSRange(location: i, length: commentEnd - i))
                i = commentEnd
                continue
            }

            // Triple-quoted strings (Python)
            if language == "python" && i + 2 < length {
                let c0 = nsCode.character(at: i)
                let c1 = nsCode.character(at: i + 1)
                let c2 = nsCode.character(at: i + 2)
                if (c0 == c1 && c1 == c2) && (c0 == 0x22 || c0 == 0x27) {
                    let delim = Character(UnicodeScalar(UInt32(c0))!)
                    let openEnd = i + 3
                    let closeRange = nsCode.range(of: String(repeating: delim, count: 3), range: NSRange(location: openEnd, length: length - openEnd))
                    if closeRange.location != NSNotFound {
                        let end = closeRange.location + closeRange.length
                        highlighted.addAttribute(.foregroundColor, value: stringColor, range: NSRange(location: i, length: end - i))
                        i = end
                    } else {
                        highlighted.addAttribute(.foregroundColor, value: stringColor, range: NSRange(location: i, length: length - i))
                        break
                    }
                    continue
                }
            }

            // String literals
            if char == 0x22 || char == 0x27 {
                let delimiter = Character(UnicodeScalar(UInt32(char))!)
                let stringEnd = SyntaxScanner.findStringEnd(from: i + 1, delimiter: delimiter, in: nsCode, escaped: true)
                highlighted.addAttribute(.foregroundColor, value: stringColor, range: NSRange(location: i, length: stringEnd - i))
                i = stringEnd
                continue
            }

            // Numbers
            if SyntaxScanner.isNumberStart(at: i, in: nsCode, length: length) {
                let numEnd = SyntaxScanner.findNumberEnd(from: i, in: nsCode, length: length)
                highlighted.addAttribute(.foregroundColor, value: numberColor, range: NSRange(location: i, length: numEnd - i))
                i = numEnd
                continue
            }

            // Preprocessor directives
            if char == 0x23, let ppRange = SyntaxScanner.preprocessorRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: preprocessorColor, range: NSRange(location: ppRange.location, length: ppRange.length))
                i = ppRange.location + ppRange.length
                continue
            }

            // Attributes / decorators (@ prefix)
            if char == 0x40, let attrRange = SyntaxScanner.attributeRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: attributeColor, range: NSRange(location: attrRange.location, length: attrRange.length))
                i = attrRange.location + attrRange.length
                continue
            }

            // HTML tags and attributes
            if language == "html", char == 0x3C, let htmlRange = SyntaxScanner.htmlRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: htmlTagColor, range: NSRange(location: htmlRange.location, length: htmlRange.length))
                i = htmlRange.location + htmlRange.length
                continue
            }

            // CSS property names
            if language == "css", let cssRange = SyntaxScanner.cssPropertyRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: cssPropertyColor, range: NSRange(location: cssRange.location, length: cssRange.length))
                i = cssRange.location + cssRange.length
                continue
            }

            // Markdown syntax characters
            if language == "markdown" || language == "md", let mdRange = SyntaxScanner.markdownSyntaxRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: markdownColor, range: NSRange(location: mdRange.location, length: mdRange.length))
                i = mdRange.location + mdRange.length
                continue
            }

            // Operators (multi-character aware)
            if let opRange = SyntaxScanner.operatorRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: operatorColor, range: NSRange(location: opRange.location, length: opRange.length))
                i = opRange.location + opRange.length
                continue
            }

            // Keywords / types / literals / functions — richer palette
            if let wordEnd = SyntaxScanner.findWordEnd(at: i, in: nsCode, length: length) {
                let word = nsCode.substring(with: NSRange(location: i, length: wordEnd - i))
                let lower = word.lowercased()
                let range = NSRange(location: i, length: wordEnd - i)
                if literals.contains(word) || literals.contains(lower) {
                    highlighted.addAttribute(.foregroundColor, value: literalColor, range: range)
                } else if typeKeywords.contains(lower) {
                    highlighted.addAttribute(.foregroundColor, value: typeColor, range: range)
                } else if SyntaxScanner.isFunctionCall(at: wordEnd, in: nsCode, length: length) {
                    // Function / method call — `foo(` — distinct from keywords
                    highlighted.addAttribute(.foregroundColor, value: functionColor, range: range)
                } else if def.keywords.contains(word) || def.keywords.contains(lower) {
                    highlighted.addAttribute(.foregroundColor, value: keywordColor, range: range)
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                    // Capitalised identifier likely a type / class / constructor
                    highlighted.addAttribute(.foregroundColor, value: typeColor, range: range)
                }
                i = wordEnd
                continue
            }

            i += 1
        }

        return highlighted
    }
}
