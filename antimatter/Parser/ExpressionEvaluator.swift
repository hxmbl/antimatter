import Foundation

/// Tiny recursive-descent evaluator for plain arithmetic: `+ - * / % ^`,
/// parentheses, unary sign, decimals, and the typographic operators
/// `× ÷ − – —`. `^` is right-associative. Returns `nil` unless the whole
/// input parses and the result is finite, so partial expressions and
/// nonsense simply stay text.
nonisolated enum ExpressionEvaluator {
    static func evaluate(_ input: String) -> Double? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        let value = expression(tokens, &cursor)
        guard cursor == tokens.count, let value, value.isFinite else { return nil }
        return value
    }

    // MARK: Tokenizer

    private enum Token {
        case number(Double)
        case op(Character)
        case lparen
        case rparen
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var digits: [Character] = []

        func flushNumber() {
            guard !digits.isEmpty else { return }
            if let value = Double(String(digits)) {
                tokens.append(.number(value))
            } else {
                tokens.append(.op("\u{0}")) // poison token: never parses
            }
            digits.removeAll()
        }

        for character in input {
            switch character {
            case " ", "\t":
                flushNumber()
            case "0"..."9", ".":
                digits.append(character)
            case "×", "·":
                flushNumber()
                tokens.append(.op("*"))
            case "÷":
                flushNumber()
                tokens.append(.op("/"))
            case "−", "–", "—":
                flushNumber()
                tokens.append(.op("-"))
            case "+", "-", "*", "/", "%", "^":
                flushNumber()
                tokens.append(.op(character))
            case "(":
                flushNumber()
                tokens.append(.lparen)
            case ")":
                flushNumber()
                tokens.append(.rparen)
            default:
                flushNumber()
                return [] // any other character means "this is not arithmetic"
            }
        }
        flushNumber()
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
    // primary    := number | '(' expression ')'

    private static func expression(_ tokens: [Token], _ cursor: inout Int) -> Double? {
        guard var value = term(tokens, &cursor) else { return nil }
        while case .op(let op)? = peek(tokens, &cursor), op == "+" || op == "-" {
            cursor += 1
            guard let rhs = term(tokens, &cursor) else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private static func term(_ tokens: [Token], _ cursor: inout Int) -> Double? {
        guard var value = power(tokens, &cursor) else { return nil }
        while case .op(let op)? = peek(tokens, &cursor), op == "*" || op == "/" || op == "%" {
            cursor += 1
            guard let rhs = power(tokens, &cursor) else { return nil }
            switch op {
            case "*": value *= rhs
            case "/": value /= rhs
            default: value = value.truncatingRemainder(dividingBy: rhs)
            }
        }
        return value
    }

    private static func power(_ tokens: [Token], _ cursor: inout Int) -> Double? {
        guard let base = unary(tokens, &cursor) else { return nil }
        if case .op("^")? = peek(tokens, &cursor) {
            cursor += 1
            guard let exponent = power(tokens, &cursor) else { return nil }
            return pow(base, exponent)
        }
        return base
    }

    private static func unary(_ tokens: [Token], _ cursor: inout Int) -> Double? {
        switch peek(tokens, &cursor) {
        case .op("-"):
            cursor += 1
            guard let value = unary(tokens, &cursor) else { return nil }
            return -value
        case .op("+"):
            cursor += 1
            return unary(tokens, &cursor)
        default:
            return primary(tokens, &cursor)
        }
    }

    private static func primary(_ tokens: [Token], _ cursor: inout Int) -> Double? {
        switch peek(tokens, &cursor) {
        case .number(let value):
            cursor += 1
            return value
        case .lparen:
            cursor += 1
            guard let value = expression(tokens, &cursor),
                  case .rparen? = peek(tokens, &cursor) else { return nil }
            cursor += 1
            return value
        default:
            return nil
        }
    }
}
