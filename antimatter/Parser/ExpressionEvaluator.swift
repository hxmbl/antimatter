import Foundation

/// Tiny recursive-descent evaluator for plain arithmetic: `+ - * / % ^`,
/// parentheses, unary sign, decimals, the typographic operators `× ÷ − – —`,
/// a handful of functions (`sqrt`, `abs`, `round`, `min`, `max`), and
/// variables resolved through a caller-supplied table. `^` is
/// right-associative. Returns `nil` unless the whole input parses and the
/// result is finite, so partial expressions, unknown names, and nonsense
/// simply stay text.
nonisolated enum ExpressionEvaluator {
    static func evaluate(_ input: String, variables: [String: Double] = [:]) -> Double? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        let value = expression(tokens, &cursor, variables)
        guard cursor == tokens.count, let value, value.isFinite else { return nil }
        return value
    }

    /// The numeric literals of an arithmetic line, in order — or nil when
    /// the line is not pure arithmetic (prose, timers, dates with letters).
    /// Aggregation uses this to collect "the numbers in the note".
    static func numericLiterals(_ input: String) -> [Double]? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        guard expression(tokens, &cursor, [:]) != nil, cursor == tokens.count else { return nil }
        return tokens.compactMap {
            if case .number(let value) = $0 { return value }
            return nil
        }
    }

    // MARK: Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case name(String)
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
            if let value = Double(String(digits)) {
                tokens.append(.number(value))
            } else {
                tokens.append(.op("\u{0}")) // poison token: never parses
            }
            digits.removeAll()
        }

        func flushName() {
            guard !letters.isEmpty else { return }
            tokens.append(.name(String(letters).lowercased()))
            letters.removeAll()
        }

        for character in input {
            switch character {
            case " ", "\t":
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
            default:
                flushNumber(); flushName()
                return [] // any other character means "this is not arithmetic"
            }
        }
        flushNumber(); flushName()
        return tokens
    }

    private static func peek(_ tokens: [Token], _ cursor: inout Int) -> Token? {
        cursor < tokens.count ? tokens[cursor] : nil
    }

    // MARK: Grammar
    //
    // expression := term (('+' | '-') term)*
    // term       := power (('*' | '/' | '%') power)*
    // power      := unary ('^' power)?          right-associative
    // unary      := ('+' | '-') unary | primary
    // primary    := number | name '(' args ')' | name | '(' expression ')'
    // args       := expression (',' expression)*

    private static func expression(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double]) -> Double? {
        guard var value = term(tokens, &cursor, vars) else { return nil }
        while case .op(let op)? = peek(tokens, &cursor), op == "+" || op == "-" {
            cursor += 1
            guard let rhs = term(tokens, &cursor, vars) else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private static func term(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double]) -> Double? {
        guard var value = power(tokens, &cursor, vars) else { return nil }
        while case .op(let op)? = peek(tokens, &cursor), op == "*" || op == "/" || op == "%" {
            cursor += 1
            guard let rhs = power(tokens, &cursor, vars) else { return nil }
            switch op {
            case "*": value *= rhs
            case "/": value /= rhs
            default: value = value.truncatingRemainder(dividingBy: rhs)
            }
        }
        return value
    }

    private static func power(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double]) -> Double? {
        guard let base = unary(tokens, &cursor, vars) else { return nil }
        if case .op("^")? = peek(tokens, &cursor) {
            cursor += 1
            guard let exponent = power(tokens, &cursor, vars) else { return nil }
            return pow(base, exponent)
        }
        return base
    }

    private static func unary(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double]) -> Double? {
        switch peek(tokens, &cursor) {
        case .op("-"):
            cursor += 1
            guard let value = unary(tokens, &cursor, vars) else { return nil }
            return -value
        case .op("+"):
            cursor += 1
            return unary(tokens, &cursor, vars)
        default:
            return primary(tokens, &cursor, vars)
        }
    }

    private static func primary(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double]) -> Double? {
        switch peek(tokens, &cursor) {
        case .number(let value):
            cursor += 1
            return value
        case .name(let name):
            cursor += 1
            guard case .lparen? = peek(tokens, &cursor) else {
                return vars[name] // an unknown variable leaves the whole line as text
            }
            cursor += 1
            guard let args = arguments(tokens, &cursor, vars), args.count >= 1 else { return nil }
            return applyFunction(name, args)
        case .lparen:
            cursor += 1
            guard let value = expression(tokens, &cursor, vars),
                  case .rparen? = peek(tokens, &cursor) else { return nil }
            cursor += 1
            return value
        default:
            return nil
        }
    }

    private static func arguments(_ tokens: [Token], _ cursor: inout Int, _ vars: [String: Double]) -> [Double]? {
        var args: [Double] = []
        guard let first = expression(tokens, &cursor, vars) else { return nil }
        args.append(first)
        while case .comma? = peek(tokens, &cursor) {
            cursor += 1
            guard let next = expression(tokens, &cursor, vars) else { return nil }
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
}
