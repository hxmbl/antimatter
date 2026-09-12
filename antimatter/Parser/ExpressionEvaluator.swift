import Foundation

nonisolated enum ExpressionEvaluator {
    static func evaluate(_ input: String, variables: [String: Double] = [:]) -> Double? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        let value = expression(tokens, &cursor, variables)
        guard cursor == tokens.count, let value, value.isFinite else { return nil }
        return value
    }

     static func numericLiterals(_ input: String) -> [Double]? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        var cursor = 0
        guard expression(tokens, &cursor, [:]) != nil, cursor == tokens.count else { return nil }

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
            case .name:
                expectsOperand = false
            }
        }
        return literals
    }

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
                    return []
            }
        }
        flushNumber(); flushName()
        return tokens
    }

    private static func peek(_ tokens: [Token], _ cursor: inout Int) -> Token? {
        cursor < tokens.count ? tokens[cursor] : nil
    }

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
                return vars[name] // unknown variable leaves line as text
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
