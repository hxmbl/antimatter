import Foundation

/// Definition of a programming language for syntax highlighting.
struct LanguageDef {
    let keywords: Set<String>
    let commentPrefix: String
    let blockCommentStart: String?
    let blockCommentEnd: String?
}

/// A registry of programming language definitions.
enum SyntaxLanguageRegistry {
    // MARK: - Language Constants

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

    // MARK: - Registry Methods

    static func definition(for lang: String) -> LanguageDef? {
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
}
