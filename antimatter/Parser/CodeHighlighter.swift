import AppKit
import Foundation

// MARK: - Syntax Highlighter

/// Lightweight syntax highlighter for code content.
/// Processes code strings and returns highlighted attributed strings.
enum CodeHighlighter {
    private struct LanguageDef {
        let keywords: Set<String>
        let commentPrefix: String
        let blockCommentStart: String?
        let blockCommentEnd: String?
    }

    private static func definition(for lang: String) -> LanguageDef? {
        switch lang {
        case "swift":
            return LanguageDef(
                keywords: [
                    "import", "let", "var", "func", "class", "struct", "enum", "protocol",
                    "extension", "if", "else", "guard", "switch", "case", "default",
                    "for", "while", "repeat", "return", "break", "continue", "fallthrough",
                    "try", "catch", "throw", "throws", "rethrows", "async", "await",
                    "in", "is", "as", "some", "any", "self", "Self", "super",
                    "true", "false", "nil", "public", "private", "internal", "fileprivate",
                    "open", "static", "final", "override", "mutating", "nonmutating",
                    "associatedtype", "typealias", "where", "defer", "deferred",
                    "init", "deinit", "subscript", "didSet", "willSet", "get", "set",
                    "lazy", "weak", "unowned", "inout", "convenience", "required",
                    "precedencegroup", "operator", "subscript"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "python":
            return LanguageDef(
                keywords: [
                    "False", "None", "True", "and", "as", "assert", "async", "await",
                    "break", "class", "continue", "def", "del", "elif", "else", "except",
                    "finally", "for", "from", "global", "if", "import", "in", "is",
                    "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
                    "try", "while", "with", "yield", "self", "print", "range", "len",
                    "int", "str", "float", "list", "dict", "tuple", "set", "bool",
                    "type", "super", "property", "staticmethod", "classmethod"
                ],
                commentPrefix: "#",
                blockCommentStart: nil,
                blockCommentEnd: nil
            )
        case "javascript", "js":
            return LanguageDef(
                keywords: [
                    "async", "await", "break", "case", "catch", "class", "const",
                    "continue", "debugger", "default", "delete", "do", "else", "export",
                    "extends", "finally", "for", "from", "function", "if", "import",
                    "in", "instanceof", "let", "new", "of", "return", "static", "super",
                    "switch", "this", "throw", "try", "typeof", "var", "void", "while",
                    "with", "yield", "null", "undefined", "true", "false", "NaN", "Infinity",
                    "console", "document", "window", "Math", "JSON", "Promise",
                    "Array", "Object", "String", "Number", "Boolean", "Symbol",
                    "Map", "Set", "WeakMap", "WeakSet", "Date", "RegExp", "Error",
                    "setTimeout", "setInterval", "clearTimeout", "clearInterval",
                    "require", "module", "exports"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "typescript", "ts":
            return LanguageDef(
                keywords: [
                    "any", "as", "async", "await", "break", "case", "catch", "class",
                    "const", "continue", "debugger", "declare", "default", "delete",
                    "do", "else", "enum", "export", "extends", "finally", "for",
                    "from", "function", "if", "implements", "import", "in",
                    "instanceof", "interface", "let", "new", "of", "package",
                    "private", "protected", "public", "readonly", "return", "static",
                    "super", "switch", "this", "throw", "try", "type", "typeof",
                    "var", "void", "while", "with", "yield",
                    "null", "undefined", "true", "false", "never", "unknown",
                    "string", "number", "boolean", "symbol", "bigint", "object",
                    "keyof", "infer", "extends", "abstract", "override"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "rust":
            return LanguageDef(
                keywords: [
                    "as", "async", "await", "break", "const", "continue", "crate",
                    "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
                    "impl", "in", "let", "loop", "match", "mod", "move", "mut",
                    "pub", "ref", "return", "self", "Self", "static", "struct",
                    "super", "trait", "true", "type", "unsafe", "use", "where", "while",
                    "abstract", "become", "box", "do", "final", "macro", "override",
                    "priv", "typeof", "unsized", "virtual", "yield",
                    "i8", "i16", "i32", "i64", "i128", "isize",
                    "u8", "u16", "u32", "u64", "u128", "usize",
                    "f32", "f64", "bool", "char", "str", "String",
                    "Option", "Result", "Some", "None", "Ok", "Err",
                    "Vec", "Box", "Rc", "Arc", "HashMap", "HashSet",
                    "println", "eprintln", "format", "vec", "assert", "assert_eq", "assert_ne",
                    "panic", "todo", "unimplemented", "unreachable"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "go":
            return LanguageDef(
                keywords: [
                    "break", "case", "chan", "const", "continue", "default", "defer",
                    "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                    "interface", "map", "package", "range", "return", "select", "struct",
                    "switch", "type", "var",
                    "true", "false", "iota", "nil",
                    "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                    "uint32", "uint64", "uintptr", "float32", "float64", "complex64",
                    "complex128", "bool", "byte", "rune", "string", "error", "any",
                    "make", "len", "cap", "append", "copy", "delete", "new", "panic",
                    "recover", "print", "println", "close", "complex", "imag", "real"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "bash", "sh", "shell", "zsh":
            return LanguageDef(
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "while", "until",
                    "do", "done", "case", "esac", "in", "function", "return", "exit",
                    "echo", "printf", "read", "cd", "ls", "pwd", "mkdir", "rm",
                    "cp", "mv", "cat", "grep", "sed", "awk", "find", "sort",
                    "cut", "tr", "head", "tail", "wc", "chmod", "chown", "sudo",
                    "apt", "brew", "npm", "git", "docker", "curl", "wget",
                    "export", "local", "declare", "typeset", "set", "unset",
                    "source", "eval", "exec", "test", "true", "false",
                    "shift", "pushd", "popd", "dirs", "trap", "wait", "kill",
                    "sleep", "tee", "xargs", "tar", "zip", "unzip", "ssh", "scp"
                ],
                commentPrefix: "#",
                blockCommentStart: nil,
                blockCommentEnd: nil
            )
        case "c":
            return LanguageDef(
                keywords: [
                    "auto", "break", "case", "char", "const", "continue", "default",
                    "do", "double", "else", "enum", "extern", "float", "for", "goto",
                    "if", "inline", "int", "long", "register", "restrict", "return",
                    "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
                    "union", "unsigned", "void", "volatile", "while", "_Bool",
                    "_Complex", "_Imaginary", "NULL", "EOF", "stdin", "stdout", "stderr",
                    "size_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t",
                    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                    "printf", "scanf", "malloc", "calloc", "realloc", "free",
                    "memcpy", "memset", "strlen", "strcmp", "strcpy", "strcat",
                    "fopen", "fclose", "fread", "fwrite", "fprintf", "fscanf"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "cpp", "c++", "cxx":
            return LanguageDef(
                keywords: [
                    "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand",
                    "bitor", "break", "case", "catch", "char", "char8_t", "char16_t",
                    "char32_t", "class", "compl", "concept", "const", "consteval",
                    "constexpr", "constinit", "const_cast", "continue", "co_await",
                    "co_return", "co_yield", "decltype", "default", "delete", "do",
                    "double", "dynamic_cast", "else", "enum", "explicit", "export",
                    "extern", "false", "float", "for", "friend", "goto", "if",
                    "inline", "int", "long", "mutable", "namespace", "new", "noexcept",
                    "not", "not_eq", "nullptr", "operator", "or", "or_eq", "private",
                    "protected", "public", "register", "reinterpret_cast", "requires",
                    "return", "short", "signed", "sizeof", "static", "static_assert",
                    "static_cast", "struct", "switch", "template", "this", "thread_local",
                    "throw", "true", "try", "typedef", "typeid", "typename", "union",
                    "unsigned", "using", "virtual", "void", "volatile", "wchar_t",
                    "while", "xor", "xor_eq", "override", "final",
                    "std", "string", "vector", "map", "set", "pair", "tuple",
                    "unique_ptr", "shared_ptr", "make_unique", "make_shared",
                    "cout", "cin", "cerr", "endl", "size_t",
                    "string_view", "optional", "variant", "any", "array",
                    "unordered_map", "unordered_set", "deque", "list", "queue", "stack",
                    "algorithm", "iterator", "numeric", "cmath", "cstdlib", "cstring",
                    "iostream", "fstream", "sstream", "iomanip"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "java":
            return LanguageDef(
                keywords: [
                    "abstract", "assert", "boolean", "break", "byte", "case", "catch",
                    "char", "class", "const", "continue", "default", "do", "double",
                    "else", "enum", "extends", "final", "finally", "float", "for",
                    "goto", "if", "implements", "import", "instanceof", "int",
                    "interface", "long", "native", "new", "package", "private",
                    "protected", "public", "return", "short", "static", "strictfp",
                    "super", "switch", "synchronized", "this", "throw", "throws",
                    "transient", "try", "void", "volatile", "while",
                    "true", "false", "null", "var", "record", "sealed", "permits",
                    "yield", "instanceof",
                    "String", "System", "Object", "Integer", "Double", "Float",
                    "Boolean", "Character", "Long", "Short", "Byte", "Number",
                    "List", "ArrayList", "LinkedList", "Map", "HashMap", "TreeMap",
                    "Set", "HashSet", "TreeSet", "Queue", "Deque", "ArrayDeque",
                    "Collections", "Arrays", "Math", "System", "Exception",
                    "RuntimeException", "IOException", "Thread", "Runnable"
                ],
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "ruby":
            return LanguageDef(
                keywords: [
                    "BEGIN", "END", "alias", "and", "begin", "break", "case",
                    "class", "def", "defined?", "do", "else", "elsif", "end",
                    "ensure", "false", "for", "if", "in", "module", "next", "nil",
                    "not", "or", "redo", "rescue", "retry", "return", "self",
                    "super", "then", "true", "undef", "unless", "until", "when",
                    "while", "yield", "require", "require_relative", "include",
                    "extend", "attr_reader", "attr_writer", "attr_accessor",
                    "puts", "print", "gets", "chomp", "to_s", "to_i", "to_f",
                    "each", "map", "select", "reject", "reduce", "find",
                    "lambda", "proc", "block_given?", "raise", "retry",
                    "protected", "private", "public", "initialize", "new",
                    "attr", "const", "global", "local", "instance",
                    "Integer", "Float", "String", "Array", "Hash", "Symbol",
                    "Range", "Regexp", "File", "Dir", "IO", "Socket"
                ],
                commentPrefix: "#",
                blockCommentStart: "=begin",
                blockCommentEnd: "=end"
            )
        case "html":
            return LanguageDef(
                keywords: [
                    "html", "head", "body", "div", "span", "p", "a", "h1", "h2", "h3",
                    "h4", "h5", "h6", "ul", "ol", "li", "table", "tr", "td", "th",
                    "form", "input", "button", "select", "option", "textarea",
                    "img", "video", "audio", "canvas", "svg", "script", "style",
                    "link", "meta", "title", "header", "footer", "nav", "main",
                    "section", "article", "aside", "figure", "figcaption",
                    "strong", "em", "small", "br", "hr", "pre", "code",
                    "DOCTYPE", "xmlns", "charset", "viewport", "lang",
                    "class", "id", "href", "src", "alt", "width", "height",
                    "type", "name", "value", "placeholder", "action", "method",
                    "rel", "content", "data", "role", "aria"
                ],
                commentPrefix: "",
                blockCommentStart: "<!--",
                blockCommentEnd: "-->"
            )
        case "css":
            return LanguageDef(
                keywords: [
                    "color", "background", "background-color", "font", "font-size",
                    "font-weight", "font-family", "margin", "padding", "border",
                    "width", "height", "display", "position", "top", "left",
                    "right", "bottom", "float", "clear", "overflow", "z-index",
                    "opacity", "transition", "animation", "transform",
                    "flex", "grid", "align-items", "justify-content",
                    "text-align", "text-decoration", "line-height", "letter-spacing",
                    "box-shadow", "border-radius", "cursor", "content",
                    "hover", "focus", "active", "visited", "first-child", "last-child",
                    "before", "after", "not", "nth-child",
                    "solid", "dashed", "dotted", "none", "block", "inline",
                    "relative", "absolute", "fixed", "sticky",
                    "inherit", "initial", "unset", "auto", "important",
                    "em", "rem", "px", "vh", "vw", "%", "fr", "deg", "s", "ms"
                ],
                commentPrefix: "",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "json":
            return LanguageDef(
                keywords: [
                    "true", "false", "null"
                ],
                commentPrefix: "",
                blockCommentStart: nil,
                blockCommentEnd: nil
            )
        case "yaml", "yml":
            return LanguageDef(
                keywords: [
                    "true", "false", "yes", "no", "on", "off", "null", "nil",
                    "---", "..."
                ],
                commentPrefix: "#",
                blockCommentStart: nil,
                blockCommentEnd: nil
            )
        case "sql":
            return LanguageDef(
                keywords: [
                    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
                    "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX",
                    "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "FULL", "CROSS",
                    "ON", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "IS",
                    "NULL", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT",
                    "OFFSET", "UNION", "ALL", "DISTINCT", "EXISTS", "ANY", "SOME",
                    "CASE", "WHEN", "THEN", "ELSE", "END",
                    "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT",
                    "DEFAULT", "AUTO_INCREMENT", "UNIQUE", "CHECK",
                    "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
                    "GRANT", "REVOKE", "TRIGGER", "VIEW", "PROCEDURE", "FUNCTION",
                    "IF", "EXPLAIN", "ANALYZE", "WITH", "RECURSIVE",
                    "INT", "INTEGER", "BIGINT", "SMALLINT", "DECIMAL", "NUMERIC",
                    "FLOAT", "REAL", "DOUBLE", "CHAR", "VARCHAR", "TEXT", "BLOB",
                    "DATE", "TIME", "DATETIME", "TIMESTAMP", "BOOLEAN"
                ],
                commentPrefix: "--",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "markdown", "md":
            return LanguageDef(
                keywords: [],
                commentPrefix: "",
                blockCommentStart: nil,
                blockCommentEnd: nil
            )
        default:
            return nil
        }
    }

    private static let keywordColor = NSColor.systemPurple
    private static let stringColor = NSColor.systemGreen
    private static let commentColor = PaneStyle.secondaryTextNSColor
    private static let numberColor = NSColor.systemOrange

    static func highlight(code: String, language: String?, baseFont: NSFont) -> NSAttributedString {
        let highlighted = NSMutableAttributedString(string: code)
        highlighted.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: highlighted.length))

        guard let language = language?.lowercased(),
              let def = definition(for: language) else {
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
                   let endRange = findString(end, in: nsCode, from: i) {
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
               findString(start, in: nsCode, from: i)?.location == i {
                if let end = def.blockCommentEnd,
                   let endRange = findString(end, in: nsCode, from: i + start.count) {
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
               findString(def.commentPrefix, in: nsCode, from: i)?.location == i {
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
                let stringEnd = findStringEnd(from: i + 1, delimiter: delimiter, in: nsCode, escaped: true)
                highlighted.addAttribute(.foregroundColor, value: stringColor, range: NSRange(location: i, length: stringEnd - i))
                i = stringEnd
                continue
            }

            // Numbers
            if isNumberStart(at: i, in: nsCode, length: length) {
                let numEnd = findNumberEnd(from: i, in: nsCode, length: length)
                highlighted.addAttribute(.foregroundColor, value: numberColor, range: NSRange(location: i, length: numEnd - i))
                i = numEnd
                continue
            }

            // Keywords
            if let wordEnd = findWordEnd(at: i, in: nsCode, length: length) {
                let word = nsCode.substring(with: NSRange(location: i, length: wordEnd - i))
                if def.keywords.contains(word) || def.keywords.contains(word.lowercased()) {
                    highlighted.addAttribute(.foregroundColor, value: keywordColor, range: NSRange(location: i, length: wordEnd - i))
                }
                i = wordEnd
                continue
            }

            i += 1
        }

        return highlighted
    }

    private static func findString(_ needle: String, in haystack: NSString, from start: Int) -> NSRange? {
        let range = haystack.range(of: needle, range: NSRange(location: start, length: haystack.length - start))
        return range.location == NSNotFound ? nil : range
    }

    private static func findStringEnd(from start: Int, delimiter: Character, in nsCode: NSString, escaped: Bool) -> Int {
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

    private static func isNumberStart(at i: Int, in nsCode: NSString, length: Int) -> Bool {
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

    private static func findNumberEnd(from start: Int, in nsCode: NSString, length: Int) -> Int {
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

    private static func findWordEnd(at start: Int, in nsCode: NSString, length: Int) -> Int? {
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
}
