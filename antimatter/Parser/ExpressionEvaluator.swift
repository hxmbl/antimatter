import Foundation

// MARK: - Expression evaluation

nonisolated enum ExpressionEvaluator {
    // MARK: Public API

    /// Evaluates `input`. `variables` resolve bare names; `$()` spans are
    /// resolved by math first, then by a side-effect-free command dry-run
    /// that needs the note's `buffer` for whole-note aggregates.
    static func evaluate(_ input: String, variables: [String: Double] = [:], buffer: String? = nil) -> Double? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        let value = expression(tokens, &cursor, variables, buffer)
        guard cursor == tokens.count, let value, value.isFinite else { return nil }
        return value
    }

     static func numericLiterals(_ input: String, buffer: String? = nil) -> [Double]? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        guard expression(tokens, &cursor, [:], buffer) != nil, cursor == tokens.count else { return nil }

        var literals: [Double] = []
        var sign = 1.0
        var expectsOperand = true
        for token in tokens {
            switch token {
            case .number(let value):
                literals.append(sign * value)
                sign = 1
                expectsOperand = false
            case .op(let op) where op == "-" && expectsOperand:
                sign = -sign // unary minus: stays expecting an operand
            case .op(let op):
                // A binary minus subtracts, so the following operand counts
                // as negative; any other operator starts a positive operand.
                sign = op == "-" ? -1 : 1
                expectsOperand = true
            case .lparen, .comma:
                sign = 1 // `-(2+3)` negates the group, not its literals
                expectsOperand = true
            case .rparen:
                expectsOperand = false
            case .name, .interpolate:
                expectsOperand = false
            }
        }
        return literals
    }

    /// Every signed number in `input`, in order — tolerant of lists and
    /// prose (`10 20 30` → [10, 20, 30]; `-5, 3` → [-5, 3]). Unlike
    /// `numericLiterals` it doesn't require the input to be one expression.
    static func listLiterals(_ input: String) -> [Double] {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return [] }
        var literals: [Double] = []
        var sign = 1.0
        var expectsOperand = true
        for token in tokens {
            switch token {
            case .number(let value):
                literals.append(sign * value)
                sign = 1
                expectsOperand = false
            case .op(let op) where op == "-" && expectsOperand:
                sign = -sign // unary minus: stays expecting an operand
            case .lparen, .comma:
                sign = 1
                expectsOperand = true
            case .op, .rparen:
                sign = 1
                expectsOperand = true
            case .name, .interpolate:
                expectsOperand = false
            }
        }
        return literals
    }

    /// Returns balanced `$()` spans as UTF-16 ranges plus their inner text.
    /// The ranges preserve the source indexes used by AppKit text storage.
    static func interpolationSpans(in input: String) -> [(range: NSRange, inner: String)] {
        let ns = input as NSString
        var spans: [(range: NSRange, inner: String)] = []
        var index = 0
        while index + 1 < ns.length {
            guard ns.character(at: index) == unichar(36), ns.character(at: index + 1) == unichar(40) else {
                index += 1
                continue
            }
            let start = index
            var cursor = index + 2
            var depth = 1
            var closed = false
            while cursor < ns.length {
                switch ns.character(at: cursor) {
                case unichar(40): depth += 1
                case unichar(41):
                    depth -= 1
                    if depth == 0 {
                        let innerRange = NSRange(location: start + 2, length: cursor - start - 2)
                        spans.append((NSRange(location: start, length: cursor - start + 1), ns.substring(with: innerRange)))
                        index = cursor + 1
                        closed = true
                    }
                default: break
                }
                if closed { break }
                cursor += 1
            }
            if !closed { index = start + 2 }
        }
        return spans
    }

    // MARK: Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case name(String)
        case interpolate(String)
        case lparen
        case rparen
        case comma
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var digits: [Character] = []
        var letters: [Character] = []

        func flushNumber() {
            guard !digits.isEmpty else { return }
            let s = String(digits)
             guard !s.hasSuffix("."), let value = Double(s) else {
                 tokens.append(.op("\u{0}"))
                     digits.removeAll()
                return
            }
            tokens.append(.number(value))
            digits.removeAll()
        }

        func flushName() {
            guard !letters.isEmpty else { return }
            tokens.append(.name(String(letters).lowercased()))
            letters.removeAll()
        }

        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            switch character {
            case " ", "\t", ":":
                // Whitespace separates tokens; `:` marks a variable reference
                // (`:sum`) so it just separates, letting the name that
                // follows flush as its own token.
                flushNumber(); flushName()
            case "0"..."9", ".":
                flushName()
                digits.append(character)
            case "a"..."z", "A"..."Z", "_":
                flushNumber()
                letters.append(character)
            case "×", "·":
                flushNumber(); flushName()
                tokens.append(.op("*"))
            case "÷":
                flushNumber(); flushName()
                tokens.append(.op("/"))
            case "−", "–", "—":
                flushNumber(); flushName()
                tokens.append(.op("-"))
            case "+", "-", "*", "/", "%", "^":
                flushNumber(); flushName()
                tokens.append(.op(character))
            case "(":
                flushNumber(); flushName()
                tokens.append(.lparen)
            case ")":
                flushNumber(); flushName()
                tokens.append(.rparen)
            case ",":
                flushNumber(); flushName()
                tokens.append(.comma)
            case "$":
                flushNumber(); flushName()
                guard let (inner, closing) = interpolateSpan(in: input, at: index) else {
                    return []
                }
                tokens.append(.interpolate(inner))
                index = closing
            default:
                flushNumber(); flushName()
                return []
            }
            index = input.index(after: index)
        }
        flushNumber(); flushName()
        return tokens
    }

    /// Scans `$( ... )` starting at index positioned on the `$`. Returns the
    /// inner text (parens excluded) and the index of the closing `)`, or nil
    /// if the span is unbalanced / not a paren.
    private static func interpolateSpan(in input: String, at dollar: String.Index) -> (String, String.Index)? {
        var cursor = input.index(after: dollar)
        guard cursor < input.endIndex, input[cursor] == "(" else { return nil }
        cursor = input.index(after: cursor)
        let start = cursor
        var depth = 1
        while cursor < input.endIndex {
            switch input[cursor] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return (String(input[start..<cursor]), cursor)
                }
            default: break
            }
            cursor = input.index(after: cursor)
        }
        return nil
    }

    // MARK: Recursive-descent parser

    private static func peek(_ tokens: [Token], _ cursor: inout Int) -> Token? {
        cursor < tokens.count ? tokens[cursor] : nil
    }

    /// expression := term (('+' | '-') term)*
    /// term       := power (('*' | '/' | '%') power)*
    /// power      := unary ('^' power)?          right-associative
    /// unary      := ('+' | '-') unary | primary
    /// primary    := number | name '(' args ')' | name | interpolate | '(' expression ')'
    /// args       := expression (',' expression)*

    private static func expression(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double], _ buffer: String?) -> Double? {
        guard var value = term(tokens, &cursor, vars, buffer) else { return nil }
        while case .op(let op)? = peek(tokens, &cursor), op == "+" || op == "-" {
            cursor += 1
            guard let rhs = term(tokens, &cursor, vars, buffer) else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private static func term(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double], _ buffer: String?) -> Double? {
        guard var value = power(tokens, &cursor, vars, buffer) else { return nil }
        while case .op(let op)? = peek(tokens, &cursor), op == "*" || op == "/" || op == "%" {
            cursor += 1
            guard let rhs = power(tokens, &cursor, vars, buffer) else { return nil }
            switch op {
            case "*": value *= rhs
            case "/": value /= rhs
            default: value = value.truncatingRemainder(dividingBy: rhs)
            }
        }
        return value
    }

    private static func power(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double], _ buffer: String?) -> Double? {
        guard let base = unary(tokens, &cursor, vars, buffer) else { return nil }
        if case .op("^")? = peek(tokens, &cursor) {
            cursor += 1
            guard let exponent = power(tokens, &cursor, vars, buffer) else { return nil }
            return pow(base, exponent)
        }
        return base
    }

    private static func unary(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double], _ buffer: String?) -> Double? {
        switch peek(tokens, &cursor) {
        case .op("-"):
            cursor += 1
            guard let value = unary(tokens, &cursor, vars, buffer) else { return nil }
            return -value
        case .op("+"):
            cursor += 1
            return unary(tokens, &cursor, vars, buffer)
        default:
            return primary(tokens, &cursor, vars, buffer)
        }
    }

    private static func primary(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double], _ buffer: String?) -> Double? {
        switch peek(tokens, &cursor) {
        case .number(let value):
            cursor += 1
            return value
        case .name(let name):
            cursor += 1
            guard case .lparen? = peek(tokens, &cursor) else {
                return vars[name] // unknown variable leaves line as text
            }
            cursor += 1
            guard let args = arguments(tokens, &cursor, vars, buffer), args.count >= 1 else { return nil }
            return applyFunction(name, args)
        case .interpolate(let inner):
            cursor += 1
            return resolveSubstitution(inner, variables: vars, buffer: buffer)
        case .lparen:
            cursor += 1
            guard let value = expression(tokens, &cursor, vars, buffer),
                  case .rparen? = peek(tokens, &cursor) else { return nil }
            cursor += 1
            return value
        default:
            return nil
        }
    }

    /// Value of a `$()` span: try math first (supports `:refs` and nested
    /// substitutions), then a side-effect-free command dry-run.
    private static func resolveSubstitution(_ inner: String, variables: [String: Double], buffer: String?) -> Double? {
        if let value = evaluate(inner, variables: variables, buffer: buffer), value.isFinite {
            return value
        }
        return IntentExecution.commandDryRun(inner, buffer: buffer)
    }

    // MARK: Function calls

    private static func arguments(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double], _ buffer: String?) -> [Double]? {
        var args: [Double] = []
        guard let first = expression(tokens, &cursor, vars, buffer) else { return nil }
        args.append(first)
        while case .comma? = peek(tokens, &cursor) {
            cursor += 1
            guard let next = expression(tokens, &cursor, vars, buffer) else { return nil }
            args.append(next)
        }
        guard case .rparen? = peek(tokens, &cursor) else { return nil }
        cursor += 1
        return args
    }

    private static func applyFunction(_ name: String, _ args: [Double]) -> Double? {
        switch name {
        case "sqrt":
            return args.count == 1 ? sqrt(args[0]) : nil
        case "abs":
            return args.count == 1 ? abs(args[0]) : nil
        case "round":
            return args.count == 1 ? args[0].rounded() : nil
        case "min":
            return args.count >= 1 ? args.min() : nil
        case "max":
            return args.count >= 1 ? args.max() : nil
        default:
            return nil
        }
    }

     // MARK: Bare-number detection

    static func isBareNumber(_ expression: String) -> Bool {
        let tokens = tokenize(expression)
        var cursor = 0
        if tokens.count >= 2, case .op(let sign)? = tokens.first, sign == "-" || sign == "+" {
            cursor = 1
        }
        guard cursor + 1 == tokens.count else { return false }
        if case .number = tokens[cursor] { return true }
        return false
    }
}
