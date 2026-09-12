import AppKit
import Foundation

/// A utility for scanning text to identify various syntax tokens.
enum SyntaxScanner {
    // MARK: - Token scanning

    static func findString(_ needle: String, in haystack: NSString, from start: Int) -> NSRange? {
        let range = haystack.range(of: needle, range: NSRange(location: start, length: haystack.length - start))
        return range.location == NSNotFound ? nil : range
    }

    static func findStringEnd(from start: Int, delimiter: Character, in nsCode: NSString, escaped: Bool) -> Int {
        var i = start
        let length = nsCode.length
        while i < length {
            let char = nsCode.character(at: i)
            if escaped && char == 0x5C {
                i += 2
                continue
            }
            if char == UInt16(delimiter.unicodeScalars.first?.value ?? 0) {
                return i + 1
            }
            i += 1
        }
        return length
    }

    static func isNumberStart(at i: Int, in nsCode: NSString, length: Int) -> Bool {
        guard i < length else { return false }
        let char = nsCode.character(at: i)
        if char >= 48 && char <= 57 { return true } // 0-9
        if char == 0x2E && i + 1 < length {
            let next = nsCode.character(at: i + 1)
            return next >= 48 && next <= 57
        }
        if char == 0x2D || char == 0x2B {
            if i + 1 < length {
                let next = nsCode.character(at: i + 1)
                return next >= 48 && next <= 57
            }
        }
        return false
    }

    static func findNumberEnd(from start: Int, in nsCode: NSString, length: Int) -> Int {
        var i = start
        var hasDot = false
        if i < length && (nsCode.character(at: i) == 0x2D || nsCode.character(at: i) == 0x2B) {
            i += 1
        }
        while i < length {
            let char = nsCode.character(at: i)
            if char >= 48 && char <= 57 {
                i += 1
            } else if !hasDot && char == 0x2E {
                hasDot = true
                i += 1
            } else {
                break
            }
        }
        return i
    }

    static func findWordEnd(at start: Int, in nsCode: NSString, length: Int) -> Int? {
        guard start < length else { return nil }
        let first = nsCode.character(at: start)
        let isIdentStart = (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95 || first == 36 // A-Z, a-z, _, $
        guard isIdentStart else { return nil }
        var i = start + 1
        while i < length {
            let c = nsCode.character(at: i)
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36 {
                i += 1
            } else {
                break
            }
        }
        return i
    }

    static func isFunctionCall(at index: Int, in nsCode: NSString, length: Int) -> Bool {
        var j = index
        while j < length {
            let c = nsCode.character(at: j)
            if c == 32 || c == 9 || c == 10 || c == 13 { // space, tab, newline
                j += 1
                continue
            }
            break
        }
        guard j < length else { return false }
        return nsCode.character(at: j) == 40 // '('
    }

    static func operatorRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
        guard i < length else { return nil }
        let char = nsCode.character(at: i)

        // Multi-character operators first (3-char, then 2-char)
        if i + 2 < length {
            let c0 = nsCode.character(at: i)
            let c1 = nsCode.character(at: i + 1)
            let c2 = nsCode.character(at: i + 2)

            if (c0, c1, c2) == (0x2E, 0x2E, 0x3C) { return NSRange(location: i, length: 3) }  // ..<
            if (c0, c1, c2) == (0x2E, 0x2E, 0x2E) { return NSRange(location: i, length: 3) }  // ...
        }

        if i + 1 < length {
            let next = nsCode.character(at: i + 1)
            let pair = UInt32(char) << 16 | UInt32(next)

            let twoCharOps: [UInt32: Int] = [
                0x3D3D: 2,  // ==
                0x213D: 2,  // !=
                0x2626: 2,  // &&
                0x7C7C: 2,  // ||
                0x2B3D: 2,  // +=
                0x2D3D: 2,  // -=
                0x2A3D: 2,  // *=
                0x2F3D: 2,  // /=
                0x253D: 2,  // %=
                0x263D: 2,  // &=
                0x7C3D: 2,  // |=
                0x5E3D: 2,  // ^=
                0x3C3C: 2,  // <<
                0x3E3E: 2,  // >>
                0x3C3D: 2,  // <=
                0x3E3D: 2,  // >=
                0x2B2B: 2,  // ++
                0x2D2D: 2,  // --
                0x3A3A: 2,  // ::
                0x3F3F: 2,  // ??
                0x3F2E: 2,  // ?.
                0x2D3E: 2,  // ->
                0x3D3E: 2,  // =>
                0x3A3D: 2,  // :=
            ]
            if let len = twoCharOps[pair] {
                return NSRange(location: i, length: len)
            }
        }

        // Single-char operators and punctuation
        let singleOps: [UInt16: Int] = [
            0x2B: 1,  // +
            0x2D: 1,  // -
            0x2A: 1,  // *
            0x2F: 1,  // /
            0x3D: 1,  // =
            0x21: 1,  // !
            0x26: 1,  // &
            0x7C: 1,  // |
            0x5E: 1,  // ^
            0x7E: 1,  // ~
            0x25: 1,  // %
            0x3C: 1,  // <
            0x3E: 1,  // >
            0x3F: 1,  // ?
            0x3A: 1,  // :
            0x3B: 1,  // ;
            0x28: 1,  // (
            0x29: 1,  // )
            0x5B: 1,  // [
            0x5D: 1,  // ]
            0x7B: 1,  // {
            0x7D: 1,  // }
            0x2C: 1,  // ,
            0x2E: 1,  // .
        ]
        if let len = singleOps[char] {
            return NSRange(location: i, length: len)
        }

        return nil
    }

    static func preprocessorRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
        guard i < length else { return nil }
        let char = nsCode.character(at: i)
        guard char == 0x23 else { return nil } // #

        // Check if # is at start of line or after whitespace
        let prevIdx = i - 1
        if prevIdx >= 0 {
            let prevChar = nsCode.character(at: prevIdx)
            if prevChar != 10 && prevChar != 13 && prevChar != 9 && prevChar != 32 { // not \n, \r, \t, space
                return nil
            }
        }

        // Find end of preprocessor line
        var j = i + 1
        while j < length {
            let c = nsCode.character(at: j)
            if c == 10 || c == 13 { break } // end of line
            j += 1
        }
        return NSRange(location: i, length: j - i)
    }

    static func attributeRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
        guard i < length else { return nil }
        let char = nsCode.character(at: i)
        guard char == 0x40 else { return nil } // @

        var j = i + 1
        while j < length {
            let c = nsCode.character(at: j)
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c == 46 {
                // A-Z, a-z, _, $, . (for module attributes like @UIApplicationMain)
                j += 1
            } else {
                break
            }
        }
        if j > i + 1 {
            return NSRange(location: i, length: j - i)
        }
        return NSRange(location: i, length: 1) // Just the @ symbol
    }

    static func htmlRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
        guard i + 1 < length else { return nil }
        let char = nsCode.character(at: i)
        guard char == 0x3C else { return nil } // <

        let next = nsCode.character(at: i + 1)
        if next == 0x2F {
            // Closing tag: </div>
            let searchRange = NSRange(location: i + 2, length: length - i - 2)
            let closeRange = nsCode.range(of: ">", range: searchRange)
            if closeRange.location != NSNotFound {
                return NSRange(location: i, length: closeRange.location - i + 1)
            }
            return NSRange(location: i, length: length - i)
        } else if (next >= 65 && next <= 90) || (next >= 97 && next <= 122) {
            // Opening tag: <div> or <div class="...">
            var j = i + 1
            while j < length {
                let c = nsCode.character(at: j)
                if c == 0x3E { // >
                    return NSRange(location: i, length: j - i + 1)
                }
                j += 1
            }
            return NSRange(location: i, length: length - i)
        } else if next == 0x21 {
            // Comment or DOCTYPE
            if i + 3 < length && nsCode.character(at: i + 1) == 0x21 && nsCode.character(at: i + 2) == 0x2D && nsCode.character(at: i + 3) == 0x2D {
                // <!--
                let closeCommentRange = nsCode.range(of: "-->", range: NSRange(location: i + 4, length: length - i - 4))
                if closeCommentRange.location != NSNotFound {
                    return NSRange(location: i, length: closeCommentRange.location - i + 3)
                }
                return NSRange(location: i, length: length - i)
            }
        }
        return nil
    }

    static func cssPropertyRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
        guard i < length else { return nil }
        let char = nsCode.character(at: i)
        guard (char >= 97 && char <= 122) else { return nil } // must start with lowercase letter

        var j = i + 1
        while j < length {
            let c = nsCode.character(at: j)
            if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 0x2D || c == 0x5F {
                // a-z, A-Z, 0-9, -, _
                j += 1
            } else {
                break
            }
        }
        // Check if followed by a colon (property definition)
        if j < length, nsCode.character(at: j) == 0x3A {
            return NSRange(location: i, length: j - i)
        }
        return nil
    }

    static func markdownSyntaxRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
        guard i < length else { return nil }
        let char = nsCode.character(at: i)

        // Headers
        if char == 0x23 { // #
            var j = i
            while j < length && nsCode.character(at: j) == 0x23 { j += 1 }
            if j > i && (j == length || nsCode.character(at: j) == 0x20) {
                return NSRange(location: i, length: j - i)
            }
        }

        // Bold/italic markers
        if char == 0x2A { // *
            if i + 1 < length && nsCode.character(at: i + 1) == 0x2A {
                if i + 2 < length && nsCode.character(at: i + 2) == 0x2A {
                    return NSRange(location: i, length: 3) // ***
                }
                return NSRange(location: i, length: 2) // **
            }
            return NSRange(location: i, length: 1) // *
        }

        if char == 0x5F { // _
            if i + 1 < length && nsCode.character(at: i + 1) == 0x5F {
                return NSRange(location: i, length: 2) // __
            }
            return NSRange(location: i, length: 1) // _
        }

        // Inline code
        if char == 0x60 { // `
            if i + 1 < length && nsCode.character(at: i + 1) == 0x60 {
                if i + 2 < length && nsCode.character(at: i + 2) == 0x60 {
                    return NSRange(location: i, length: 3) // ```
                }
                return NSRange(location: i, length: 2) // ``
            }
            return NSRange(location: i, length: 1) // `
        }

        // Links [text] or images ![alt]
        if char == 0x5B { // [
            return NSRange(location: i, length: 1)
        }
        if char == 0x5D { // ]
            return NSRange(location: i, length: 1)
        }
        if char == 0x28 { // (
            return NSRange(location: i, length: 1)
        }
        if char == 0x29 { // )
            return NSRange(location: i, length: 1)
        }
        if char == 0x21 { // !
            return NSRange(location: i, length: 1)
        }

        // Horizontal rules
        if char == 0x2D || char == 0x2A || char == 0x5F {
            var count = 0
            var j = i
            while j < length && nsCode.character(at: j) == char {
                count += 1
                j += 1
            }
            if count >= 3 {
                return NSRange(location: i, length: count)
            }
        }

        // Blockquotes
        if char == 0x3E { // >
            return NSRange(location: i, length: 1)
        }

        // Task list markers
        if char == 0x5B { // [x] or [ ]
            return NSRange(location: i, length: 1)
        }

        // Horizontal rule with ---
        if char == 0x2D {
            var j = i
            var dashCount = 0
            while j < length && nsCode.character(at: j) == 0x2D {
                dashCount += 1
                j += 1
            }
            if dashCount >= 3 && (j >= length || nsCode.character(at: j) == 0x20) {
                return NSRange(location: i, length: dashCount)
            }
        }

        return nil
    }
}
