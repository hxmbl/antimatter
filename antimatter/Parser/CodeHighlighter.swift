import AppKit
import Foundation

// MARK: - Code syntax highlighting

/// Lightweight syntax highlighter for code blocks.
enum CodeHighlighter {
    // MARK: Language definitions

    private struct LanguageDef {
        let keywords: Set<String>
        let commentPrefix: String
        let blockCommentStart: String?
        let blockCommentEnd: String?
    }

    private static let cFamilyBase: Set<String> = [
        "auto", "break", "case", "const", "continue", "default", "do", "else",
        "enum", "extern", "for", "goto", "if", "register", "return", "sizeof",
        "static", "struct", "switch", "typedef", "union", "while"
    ]
    private static let cTypes: Set<String> = [
        "char", "double", "float", "int", "long", "short", "signed", "unsigned",
        "void", "volatile"
    ]
    private static let cppExtensions: Set<String> = [
        "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor",
        "catch", "char8_t", "char16_t", "char32_t", "class", "compl", "concept",
        "consteval", "constexpr", "constinit", "const_cast", "co_await",
        "co_return", "co_yield", "decltype", "delete", "dynamic_cast", "explicit",
        "export", "false", "friend", "inline", "mutable", "namespace", "new",
        "noexcept", "not", "not_eq", "nullptr", "operator", "or", "or_eq",
        "private", "protected", "public", "reinterpret_cast", "requires",
        "static_assert", "static_cast", "template", "this", "thread_local",
        "throw", "true", "try", "typeid", "typename", "using", "virtual",
        "wchar_t", "xor", "xor_eq", "override", "final"
    ]
    private static let javaBase: Set<String> = [
        "abstract", "assert", "boolean", "byte", "catch", "char", "class",
        "const", "default", "do", "double", "else", "enum", "extends", "final",
        "finally", "float", "for", "goto", "if", "implements", "import",
        "instanceof", "int", "interface", "long", "native", "new", "package",
        "private", "protected", "public", "return", "short", "static", "strictfp",
        "super", "switch", "synchronized", "this", "throw", "throws", "transient",
        "try", "void", "volatile", "while"
    ]
    private static let jsBase: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const",
        "continue", "debugger", "default", "delete", "do", "else", "export",
        "extends", "finally", "for", "from", "function", "if", "import",
        "in", "instanceof", "let", "new", "of", "return", "static", "super",
        "switch", "this", "throw", "try", "typeof", "var", "void", "while",
        "with", "yield", "null", "undefined", "true", "false"
    ]

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
                keywords: jsBase.union([
                    "NaN", "Infinity",
                    "console", "document", "window", "Math", "JSON", "Promise",
                    "Array", "Object", "String", "Number", "Boolean", "Symbol",
                    "Map", "Set", "WeakMap", "WeakSet", "Date", "RegExp", "Error",
                    "setTimeout", "setInterval", "clearTimeout", "clearInterval",
                    "require", "module", "exports"
                ]),
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "typescript", "ts":
            return LanguageDef(
                keywords: jsBase.union([
                    "any", "as", "declare", "enum", "implements", "interface",
                    "package", "private", "protected", "public", "readonly",
                    "type", "never", "unknown",
                    "string", "number", "boolean", "symbol", "bigint", "object",
                    "keyof", "infer", "abstract", "override"
                ]),
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
                keywords: cFamilyBase.union(cTypes).union([
                    "restrict", "_Bool", "_Complex", "_Imaginary",
                    "NULL", "EOF", "stdin", "stdout", "stderr",
                    "size_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t",
                    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                    "printf", "scanf", "malloc", "calloc", "realloc", "free",
                    "memcpy", "memset", "strlen", "strcmp", "strcpy", "strcat",
                    "fopen", "fclose", "fread", "fwrite", "fprintf", "fscanf"
                ]),
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "cpp", "c++", "cxx":
            return LanguageDef(
                keywords: cFamilyBase.union(cTypes).union(cppExtensions).union([
                    "char8_t", "char16_t", "char32_t",
                    "std", "string", "vector", "map", "set", "pair", "tuple",
                    "unique_ptr", "shared_ptr", "make_unique", "make_shared",
                    "cout", "cin", "cerr", "endl", "size_t",
                    "string_view", "optional", "variant", "any", "array",
                    "unordered_map", "unordered_set", "deque", "list", "queue", "stack",
                    "algorithm", "iterator", "numeric", "cmath", "cstdlib", "cstring",
                    "iostream", "fstream", "sstream", "iomanip"
                ]),
                commentPrefix: "//",
                blockCommentStart: "/*",
                blockCommentEnd: "*/"
            )
        case "java":
            return LanguageDef(
                keywords: cFamilyBase.union(cTypes).union(javaBase).union([
                    "true", "false", "null", "var", "record", "sealed", "permits",
                    "yield",
                    "String", "System", "Object", "Integer", "Double", "Float",
                    "Boolean", "Character", "Long", "Short", "Byte", "Number",
                    "List", "ArrayList", "LinkedList", "Map", "HashMap", "TreeMap",
                    "Set", "HashSet", "TreeSet", "Queue", "Deque", "ArrayDeque",
                    "Collections", "Arrays", "Math", "Exception",
                    "RuntimeException", "IOException", "Thread", "Runnable"
                ]),
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

            // Preprocessor directives
            if char == 0x23, let ppRange = preprocessorRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: preprocessorColor, range: NSRange(location: ppRange.location, length: ppRange.length))
                i = ppRange.location + ppRange.length
                continue
            }

            // Attributes / decorators (@ prefix)
            if char == 0x40, let attrRange = attributeRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: attributeColor, range: NSRange(location: attrRange.location, length: attrRange.length))
                i = attrRange.location + attrRange.length
                continue
            }

            // HTML tags and attributes
            if language == "html", char == 0x3C, let htmlRange = htmlRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: htmlTagColor, range: NSRange(location: htmlRange.location, length: htmlRange.length))
                i = htmlRange.location + htmlRange.length
                continue
            }

            // CSS property names
            if language == "css", let cssRange = cssPropertyRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: cssPropertyColor, range: NSRange(location: cssRange.location, length: cssRange.length))
                i = cssRange.location + cssRange.length
                continue
            }

            // Markdown syntax characters
            if language == "markdown" || language == "md", let mdRange = markdownSyntaxRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: markdownColor, range: NSRange(location: mdRange.location, length: mdRange.length))
                i = mdRange.location + mdRange.length
                continue
            }

            // Operators (multi-character aware)
            if let opRange = operatorRange(at: i, in: nsCode, length: length) {
                highlighted.addAttribute(.foregroundColor, value: operatorColor, range: NSRange(location: opRange.location, length: opRange.length))
                i = opRange.location + opRange.length
                continue
            }

            // Keywords / types / literals / functions — richer palette
            if let wordEnd = findWordEnd(at: i, in: nsCode, length: length) {
                let word = nsCode.substring(with: NSRange(location: i, length: wordEnd - i))
                let lower = word.lowercased()
                let range = NSRange(location: i, length: wordEnd - i)
                if literals.contains(word) || literals.contains(lower) {
                    highlighted.addAttribute(.foregroundColor, value: literalColor, range: range)
                } else if typeKeywords.contains(lower) {
                    highlighted.addAttribute(.foregroundColor, value: typeColor, range: range)
                } else if isFunctionCall(at: wordEnd, in: nsCode, length: length) {
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

    // MARK: Token scanning

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

    private static func isFunctionCall(at index: Int, in nsCode: NSString, length: Int) -> Bool {
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


    private static func operatorRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
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


    private static func preprocessorRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
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


    private static func attributeRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
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


    private static func htmlRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
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


    private static func cssPropertyRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
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


    private static func markdownSyntaxRange(at i: Int, in nsCode: NSString, length: Int) -> NSRange? {
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
