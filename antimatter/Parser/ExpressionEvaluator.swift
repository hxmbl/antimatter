import Foundation

// MARK: - Spark values

/// The values the Spark expression language can produce. Math is the primary
/// citizen; comparisons yield booleans and quoted literals yield strings, so a
/// line can commit to `2 > 1 = true` or `"a" + "b" = "ab"` as well as
/// `384 * 27 = 10368`. Lists `[1, 2, 3]` and ranges `1..10` build collections
/// that variables and aggregates operate on.
nonisolated enum SparkValue: Equatable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case list([SparkValue])

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolean: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var list: [SparkValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var isList: Bool {
        if case .list = self { return true }
        return false
    }

    var isFinite: Bool {
        switch self {
        case .number(let value): value.isFinite
        case .boolean, .string: true
        case .list(let items): items.allSatisfy(\.isFinite)
        }
    }
}

// MARK: - Expression evaluation

nonisolated enum ExpressionEvaluator {
    // MARK: Public API

    /// Evaluates `input` to a number, or nil when it isn't one (or fails).
    /// `variables` resolve bare names; `$()` spans are resolved by math first,
    /// then by a side-effect-free command dry-run that needs the note's
    /// `buffer` for whole-note aggregates.
    static func evaluate(_ input: String, variables: [String: Double] = [:], buffer: String? = nil) -> Double? {
        guard let value = evaluateValue(input, variables: variables.mapValues { SparkValue.number($0) }, buffer: buffer),
              let number = value.number,
              number.isFinite
        else { return nil }
        return number
    }

    /// Evaluates `input` to any Spark value (number, boolean, string, or
    /// list), or nil when the expression is malformed or references an
    /// unknown name.
    static func evaluateValue(_ input: String, variables: [String: SparkValue] = [:], buffer: String? = nil) -> SparkValue? {
        evaluateValue(input, variables: variables, buffer: buffer, depth: 0)
    }

    /// `depth` seeds the caller's nesting level so `$($($(…)))` meets the same
    /// ceiling as `(((…)))`. A `$()` span is tokenized as a *single* token, so
    /// the parser's own counter cannot see inside one; without threading the
    /// level through, nested substitutions recursed unbounded exactly like
    /// nested parens used to. Seeded by `resolveSubstitution` as `depth + 1`,
    /// because entering the span *is* a nesting level.
    private static func evaluateValue(
        _ input: String,
        variables: [String: SparkValue],
        buffer: String?,
        depth: Int
    ) -> SparkValue? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        // Refuse *before* descending. Checking inside `expression` is not enough: a
        // `$()` span is one token however deeply it nests, so the parser only
        // discovers the depth by recursing into it — the guard would already be
        // on the stack. `depth` carries the level in from an enclosing span, and
        // the scan catches a span nested within this line.
        guard depth <= maxNestingDepth,
              spanNestingDepth(of: input) <= maxNestingDepth
        else { return nil }
        var state = ParseState(tokens: tokens)
        // Start at -1 so the outermost expression spends no budget: it is not
        // nested inside anything, and charging it meant 64 parens actually
        // allowed 63 — an off-by-one in a number the documentation quotes.
        state.depth = depth - 1
        guard let value = expression(&state, variables, buffer),
              state.cursor == state.tokens.count
        else { return nil }
        return value
    }

    /// A friendly explanation of why `input` doesn't evaluate, or nil when it
    /// does. Used to replace the old silent failure on return: a math-shaped
    /// line that can't run now says why instead of quietly doing nothing.
    static func error(
        in input: String,
        variables: [String: SparkValue] = [:],
        buffer: String? = nil
    ) -> String? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return "Couldn't read this as an expression" }
        // `spanNestingDepth` is a linear scan with no recursion or allocation, so
        // running it on every parse costs nothing measurable and removes the
        // temptation to reason about which token shapes need it. A `$()` span is
        // the case that *must* be caught here — it is a single token however
        // deeply it nests, so the per-level check inside `expression` only runs
        // after the recursive descent has already begun.
        guard spanNestingDepth(of: input) <= maxNestingDepth else { return nestingError }
        var state = ParseState(tokens: tokens)
        // Outermost expression spends no nesting budget — see `evaluateValue`.
        state.depth = -1
        let value = expression(&state, variables, buffer)
        if let message = state.error { return message }
        if state.cursor != state.tokens.count {
            return "Unexpected '\(describeToken(state.tokens[state.cursor]))'"
        }
        if let value, !value.isFinite {
            // `isFinite` recurses through lists, so `[ln(-1)]` is diagnosed too.
            // This only looked at `value.number`, which is non-nil for a
            // top-level NaN and nil for a list *containing* one — so the worst
            // case was silence: `looksArithmetic("[ln(-1)]")` is true, the pane
            // went looking for a reason to show, and `error(in:)` handed back
            // nil because the check could not see one level down.
            return "Result is too large or undefined"
        }
        return value == nil ? "Couldn't evaluate this expression" : nil
    }

    /// Whether a line is worth diagnosing at all: it must actually look like
    /// arithmetic (a number next to an operator or parentheses), so prose like
    /// "hello, world" or "Hey!" never raises an error hint.
    static func looksArithmetic(_ input: String) -> Bool {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return false }
        var hasNumber = false
        var hasOperator = false
        for token in tokens {
            switch token {
            case .number: hasNumber = true
            case .op, .lparen, .rparen: hasOperator = true
            default: break
            }
        }
        return hasNumber && hasOperator
    }

    /// The variable names referenced by a definition's right-hand side, in
    /// order of first mention. Used to resolve forward references. Function
    /// names and `$()` spans don't count (the latter resolve via dry-run).
    static func dependencies(in input: String) -> [String] {
        let tokens = tokenize(input)
        var deps: [String] = []
        var index = 0
        while index < tokens.count {
            if case .name(let name) = tokens[index] {
                let isFunctionCall = index + 1 < tokens.count && tokens[index + 1] == .lparen
                // Keywords (`if`/`then`/`else`), literals (`true`/`false`) and
                // constants (`pi`/`e`/`tau`) aren't references to variables.
                let reserved = ["true", "false", "if", "then", "else", "pi", "e", "tau"].contains(name)
                if !isFunctionCall, !reserved, !deps.contains(name) {
                    deps.append(name)
                }
            }
            index += 1
        }
        return deps
    }

    static func numericLiterals(_ input: String, buffer: String? = nil) -> [Double]? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        // Ranges live above this parser's level; a `..` means the input is a
        // list or range expression, which numeric-literal scanning skips.
        if tokens.contains(.op("..")) { return nil }
        var state = ParseState(tokens: tokens)
        guard orExpression(&state, [:], buffer) != nil,
              state.cursor == state.tokens.count else { return nil }

        var literals: [Double] = []
        var sign = 1.0
        var expectsOperand = true
        for token in tokens {
            switch token {
            case .number(let value, _):
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
            case .lparen, .comma, .lbracket:
                sign = 1 // `-(2+3)` negates the group, not its literals
                expectsOperand = true
            case .rparen, .rbracket:
                expectsOperand = false
            case .invalid:
                // `1.` and friends contribute no literal and leave the scan
                // expecting a fresh operand, so `1. 2` still yields `[2]`.
                expectsOperand = true
            case .name, .interpolate, .string, .not:
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
            case .number(let value, _):
                literals.append(sign * value)
                sign = 1
                expectsOperand = false
            case .op(let op) where op == "-" && expectsOperand:
                sign = -sign // unary minus: stays expecting an operand
            case .lparen, .comma, .lbracket:
                sign = 1
                expectsOperand = true
            case .op, .rparen, .rbracket:
                sign = 1
                expectsOperand = true
            case .invalid:
                expectsOperand = true
            case .name, .interpolate, .string, .not:
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
        /// The value plus the text it was written as, so a diagnostic can echo
        /// what the user typed. Carrying only the `Double` made every message
        /// quote the *parsed* number instead — `2 3` complained about an
        /// unexpected `'3.0'`, and `1e6` about `'1000000'`.
        case number(Double, source: String)
        case op(String)
        case name(String)
        case interpolate(String)
        case string(String)
        case lparen
        case rparen
        case lbracket
        case rbracket
        case comma
        case not
        /// A run of digits that is not a number (`1.`, `1.2.3`). Carries its own
        /// source text so the parser can *name* it in a diagnostic. This used to
        /// be a `NUL` stuffed into `.op`, which then reached the user verbatim
        /// as `Unexpected '<NUL>'`.
        case invalid(String)
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var digits: [Character] = []
        var letters: [Character] = []

        func flushNumber() {
            guard !digits.isEmpty else { return }
            let s = String(digits)
            guard !s.hasSuffix("."), let value = Double(s) else {
                tokens.append(.invalid(s))
                digits.removeAll()
                return
            }
            tokens.append(.number(value, source: s))
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
                if character == ".",
                   input.index(after: index) < input.endIndex,
                   input[input.index(after: index)] == "."
                {
                    // Range operator `a..b`. The decimal point is only a range
                    // when doubled, so `1.5` and `1.2.3` still behave as before.
                    flushNumber()
                    tokens.append(.op(".."))
                    index = input.index(input.index(after: index), offsetBy: 1)
                    continue
                }
                digits.append(character)
            case "a"..."z", "A"..."Z", "_":
                if (character == "e" || character == "E"),
                   !digits.isEmpty,
                   exponentFollows(in: input, at: index)
                {
                    // Scientific notation: `2e3`, `3.5E-2` stay one number.
                    digits.append(character)
                    index = input.index(after: index)
                    if input[index] == "+" || input[index] == "-" {
                        digits.append(input[index])
                        index = input.index(after: index)
                    }
                    while index < input.endIndex, input[index].isASCII, input[index].isNumber {
                        digits.append(input[index])
                        index = input.index(after: index)
                    }
                    continue
                }
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
                tokens.append(.op(String(character)))
            case ">", "<":
                flushNumber(); flushName()
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == "=" {
                    tokens.append(.op(String(character) + "="))
                    index = next
                } else {
                    tokens.append(.op(String(character)))
                }
            case "=":
                flushNumber(); flushName()
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == "=" {
                    tokens.append(.op("=="))
                    index = next
                } else {
                    return [] // a bare `=` isn't part of an expression (`a = b` stays text)
                }
            case "&", "|":
                flushNumber(); flushName()
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == character {
                    tokens.append(.op(String([character, character])))
                    index = next
                } else {
                    return []
                }
            case "!":
                flushNumber(); flushName()
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == "=" {
                    tokens.append(.op("!="))
                    index = next
                } else {
                    tokens.append(.not)
                }
            case "\"", "'":
                flushNumber(); flushName()
                guard let (inner, closing) = stringSpan(in: input, at: index) else { return [] }
                tokens.append(.string(inner))
                index = closing
            case "(":
                flushNumber(); flushName()
                tokens.append(.lparen)
            case ")":
                flushNumber(); flushName()
                tokens.append(.rparen)
            case "[":
                flushNumber(); flushName()
                tokens.append(.lbracket)
            case "]":
                flushNumber(); flushName()
                tokens.append(.rbracket)
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

    /// True when the character after `index` starts an exponent: `e` followed
    /// by a digit (or a sign and a digit), e.g. `1e10`, `3.5e-2`.
    private static func exponentFollows(in input: String, at index: String.Index) -> Bool {
        var cursor = input.index(after: index)
        guard cursor < input.endIndex else { return false }
        if input[cursor] == "+" || input[cursor] == "-" {
            cursor = input.index(after: cursor)
            guard cursor < input.endIndex else { return false }
        }
        return input[cursor].isASCII && input[cursor].isNumber
    }

    /// Scans a quoted string literal starting at `start` (the opening quote).
    /// A backslash escapes the following character; returns the inner text and
    /// the index of the closing quote, or nil when the quote never closes.
    private static func stringSpan(in input: String, at start: String.Index) -> (String, String.Index)? {
        let quote = input[start]
        var cursor = input.index(after: start)
        var inner = ""
        while cursor < input.endIndex {
            let character = input[cursor]
            if character == "\\" {
                let next = input.index(after: cursor)
                if next < input.endIndex {
                    inner.append(input[next])
                    cursor = input.index(after: next)
                    continue
                }
            }
            if character == quote {
                return (inner, cursor)
            }
            inner.append(character)
            cursor = input.index(after: cursor)
        }
        return nil
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

    /// expression := or |
    ///               'if' or 'then' expression 'else' expression
    /// or/logic := and (|| and)*
    /// and      := equality (&& equality)*
    /// equality := comparison (== comparison)*
    /// comparison := range ((> | < | >= | <=) range)*
    /// range    := additive ('..' additive)*
    /// additive := term ((+ | -) term)*
    /// term     := power ((* | / | %) power | implicit-group)*
    /// power    := unary (^ power)?              right-associative
    /// unary    := (+ | - | !) unary | primary
    /// primary  := number | string | list '[' expr (',' expr)* ']'
    ///             | name '(' args ')' | name | interpolate | '(' expression ')' | '[' expr* ']'
    ///             followed by indexing '[' expression ']'*
    /// args     := expression (',' expression)*

    private struct ParseState {
        let tokens: [Token]
        var cursor = 0
        var error: String?
        /// Nesting level: parens, list brackets, `$( )`. Bounded by
        /// `maxNestingDepth`.
        var depth = 0
        /// Length of the current run of unary operators / `^`. Bounded by
        /// `maxChainDepth`, and tracked apart from `depth` because the two are
        /// unrelated hazards.
        var chain = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }
    }

    private static func peek(_ state: inout ParseState) -> Token? {
        state.cursor < state.tokens.count ? state.tokens[state.cursor] : nil
    }

    /// Records the first failure only, so the deepest/most useful message wins.
    private static func setError(_ state: inout ParseState, _ message: String) {
        if state.error == nil { state.error = message }
    }

    /// The top of the expression grammar. Adds `if ... then ... else`
    /// conditionals over the Boolean chain.
    ///
    /// This is where the nesting ceiling belongs, and the placement is not
    /// arbitrary. One paren costs *eleven* stack frames — `expression`,
    /// `orExpression`, `andExpression`, `equality`, `comparison`, `range`,
    /// `additive`, `term`, `power`, `unary`, `primary` — so a guard on any
    /// single link of that chain is a guard on one frame in eleven. Mine was on
    /// `primaryAtom`, which meant 64 parens still recursed ~700 frames deep, and
    /// a test host with a smaller stack than the main thread died on it: a
    /// 50,000-paren line crashed `xctest` while passing standalone. The ceiling
    /// has to sit where a nesting construct is *entered*, which is exactly one
    /// level per level, and `expression` is reached once per nesting construct
    /// — from `primaryAtom`'s paren case, its bracket case, and `if`'s branches.
    private static func expression(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        state.depth += 1
        defer { state.depth -= 1 }
        guard state.depth <= maxNestingDepth else {
            setError(&state, nestingError)
            return nil
        }
        guard case .name("if")? = peek(&state) else {
            return orExpression(&state, variables, buffer)
        }
        return ifExpression(&state, variables, buffer)
    }

    private static let nestingError = "That expression is nested too deeply"

    private static let chainError = "That expression has too many operators in a row"

    private static func ifExpression(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        state.cursor += 1 // consume `if`
        guard let condition = orExpression(&state, variables, buffer) else { return nil }
        guard let test = condition.boolean else {
            setError(&state, "Expected a boolean after 'if'")
            return nil
        }
        guard case .name("then")? = peek(&state) else {
            setError(&state, "Expected 'then'")
            return nil
        }
        state.cursor += 1
        // Only the taken branch's value matters. The other branch is still
        // parsed so it validates, but a runtime failure there (say a division
        // by zero) can't sink an `if` that never selects it — the classic
        // `if x > 0 then 100 / x else 0` must not error when x is 0.
        let taken: SparkValue?
        if test {
            taken = expression(&state, variables, buffer)
        } else {
            var scratch = state
            _ = expression(&scratch, variables, buffer)
            state.cursor = scratch.cursor
            taken = nil
        }
        guard case .name("else")? = peek(&state) else {
            setError(&state, "Expected 'else'")
            return nil
        }
        state.cursor += 1
        if test {
            // Consume the untaken branch so an outer caller (parens, `+ 1`)
            // sees a fully-parsed expression, but its errors stay isolated.
            var scratch = state
            _ = expression(&scratch, variables, buffer)
            state.cursor = scratch.cursor
            return taken
        }
        return expression(&state, variables, buffer)
    }

    private static func orExpression(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard var value = andExpression(&state, variables, buffer) else { return nil }
        while case .op("||")? = peek(&state) {
            state.cursor += 1
            guard let rhs = andExpression(&state, variables, buffer) else {
                setError(&state, "Expected a value after '||'")
                return nil
            }
            guard let lhs = value.boolean, let rhsBool = rhs.boolean else {
                setError(&state, "Expected booleans around '||'")
                return nil
            }
            value = .boolean(lhs || rhsBool)
        }
        return value
    }

    private static func andExpression(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard var value = equality(&state, variables, buffer) else { return nil }
        while case .op("&&")? = peek(&state) {
            state.cursor += 1
            guard let rhs = equality(&state, variables, buffer) else {
                setError(&state, "Expected a value after '&&'")
                return nil
            }
            guard let lhs = value.boolean, let rhsBool = rhs.boolean else {
                setError(&state, "Expected booleans around '&&'")
                return nil
            }
            value = .boolean(lhs && rhsBool)
        }
        return value
    }

    private static func equality(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard var value = comparison(&state, variables, buffer) else { return nil }
        while case .op(let op)? = peek(&state), op == "==" || op == "!=" {
            state.cursor += 1
            guard let rhs = comparison(&state, variables, buffer) else {
                setError(&state, "Expected a value after '\(op)'")
                return nil
            }
            switch (value, rhs) {
            case (.number(let lhs), .number(let rhsNumber)):
                value = .boolean(op == "==" ? lhs == rhsNumber : lhs != rhsNumber)
            case (.string(let lhs), .string(let rhsString)):
                value = .boolean(op == "==" ? lhs == rhsString : lhs != rhsString)
            case (.boolean(let lhs), .boolean(let rhsBool)):
                value = .boolean(op == "==" ? lhs == rhsBool : lhs != rhsBool)
            case (.list(let lhs), .list(let rhsList)):
                // Structural, recursively — `SparkValue` is already `Equatable`.
                // This arm used to be missing, so two identical lists fell
                // through to `default:` and compared *unequal*: `[1, 2] == [1, 2]`
                // answered `false` and, being a finite non-list value, committed
                // `1..5 == 1..5 = false` to the note and kept it on every
                // reactive pass. A confidently wrong answer that persists is
                // worse here than an error, because the whole language is built
                // around never committing one.
                value = .boolean(op == "==" ? lhs == rhsList : lhs != rhsList)
            default:
                // Comparing *different* kinds is never an error, just unequal.
                value = .boolean(op == "!=")
            }
        }
        return value
    }

    private static func comparison(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard var value = range(&state, variables, buffer) else { return nil }
        while case .op(let op)? = peek(&state), op == ">" || op == "<" || op == ">=" || op == "<=" {
            state.cursor += 1
            guard let rhs = range(&state, variables, buffer) else {
                setError(&state, "Expected a value after '\(op)'")
                return nil
            }
            guard let lhs = value.number, let rhsNumber = rhs.number else {
                setError(&state, "Comparisons need numbers")
                return nil
            }
            switch op {
            case ">": value = .boolean(lhs > rhsNumber)
            case "<": value = .boolean(lhs < rhsNumber)
            case ">=": value = .boolean(lhs >= rhsNumber)
            default: value = .boolean(lhs <= rhsNumber)
            }
        }
        return value
    }

    /// range := additive ('..' additive)*
    /// A range is an inclusive, ascending sequence of whole numbers:
    /// `1..5` → [1, 2, 3, 4, 5]; `3..1` → []. Descending ranges are empty
    /// rather than errors, and absurdly large ones refuse to build.
    private static func range(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard var value = additive(&state, variables, buffer) else { return nil }
        while case .op("..")? = peek(&state) {
            state.cursor += 1
            guard let end = additive(&state, variables, buffer) else {
                setError(&state, "Ranges need numbers on both sides")
                return nil
            }
            guard let start = value.number, let endNumber = end.number else {
                setError(&state, "Ranges need numbers on both sides")
                return nil
            }
            guard let first = Int(exactly: start), let last = Int(exactly: endNumber) else {
                setError(&state, "Ranges need whole numbers")
                return nil
            }
            guard first <= last else {
                setError(&state, "Ranges go upward")
                return nil
            }
            // Ordering the bounds rules out *underflow*, not overflow: `-5e18 ..
            // 5e18` is ordered and still 1e19 wide, which no `Int` holds. So the
            // width is measured with a checked subtraction and a width that
            // doesn't fit is simply "too large" — which it demonstrably is,
            // being wider than `Int.max` and so than the cap. The count used to
            // be `last - first + 1` computed before *any* of these checks, so
            // that input trapped instead of reporting an error, and it killed
            // the process rather than the line: `VariableTable.scan` runs on
            // every repaint, so one such definition crashed the app every time
            // the note was drawn.
            //
            // `width` is one less than the entry count, so `< rangeCap` here is
            // the same limit as `<= rangeCap` on the count.
            let (width, overflowed) = last.subtractingReportingOverflow(first)
            guard !overflowed, width < rangeCap else {
                setError(&state, "That range is too large")
                return nil
            }
            value = .list((first...last).map { .number(Double($0)) })
        }
        return value
    }

    private static func additive(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard var value = term(&state, variables, buffer) else { return nil }
        while case .op(let op)? = peek(&state), op == "+" || op == "-" {
            state.cursor += 1
            guard let rhs = term(&state, variables, buffer) else {
                setError(&state, "Expected a value after '\(op)'")
                return nil
            }
            if let lhs = value.number, let rhsNumber = rhs.number {
                value = .number(op == "+" ? lhs + rhsNumber : lhs - rhsNumber)
            } else if op == "+", let lhs = value.string, let rhsString = rhs.string {
                value = .string(lhs + rhsString)
            } else {
                setError(&state, "Can't \(op == "+" ? "add" : "subtract") these")
                return nil
            }
        }
        return value
    }

    private static func term(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard var value = power(&state, variables, buffer) else { return nil }
        while true {
            switch peek(&state) {
            case .op(let op) where op == "*" || op == "/" || op == "%":
                state.cursor += 1
                guard let rhs = power(&state, variables, buffer),
                      let lhs = value.number,
                      let rhsNumber = rhs.number
                else {
                    setError(&state, "Expected a value after '\(op)'")
                    return nil
                }
                switch op {
                case "*":
                    value = .number(lhs * rhsNumber)
                case "/":
                    guard rhsNumber != 0 else {
                        setError(&state, "Division by zero")
                        return nil
                    }
                    value = .number(lhs / rhsNumber)
                default:
                    // `%` is `truncatingRemainder`, which is NaN for a zero
                    // divisor. Guard it like `/` so the diagnostic says
                    // "Division by zero" instead of surfacing a non-finite
                    // result the caller has to second-guess.
                    guard rhsNumber != 0 else {
                        setError(&state, "Division by zero")
                        return nil
                    }
                    value = .number(lhs.truncatingRemainder(dividingBy: rhsNumber))
                }
            case .lparen:
                // Implicit multiplication: `2(3+4)` = `2*(3+4)`, `(2)(3)` = 6.
                guard let rhs = power(&state, variables, buffer),
                      let lhs = value.number,
                      let rhsNumber = rhs.number
                else {
                    setError(&state, "Can't multiply these")
                    return nil
                }
                value = .number(lhs * rhsNumber)
            default:
                return value
            }
        }
    }

    private static func power(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard let base = unary(&state, variables, buffer) else { return nil }
        guard case .op("^")? = peek(&state) else { return base }
        guard let baseNumber = base.number else {
            setError(&state, "Can't raise this to a power")
            return nil
        }
        state.cursor += 1
        // A lone `^` with nothing after it: `2^`. Handled before the loop so the
        // operand list is never empty to index into.
        guard let first = unary(&state, variables, buffer)?.number else {
            setError(&state, "Expected a value after '^'")
            return nil
        }
        // Right-associative, so the exponent is the rest of the chain: `2^3^2`
        // is `2^(3^2)`. Walk it iteratively and collect the operands, then fold
        // from the right. Recursing per `^` put one stack frame per operator, so
        // `2^2^2^…` was bounded only by however deep the stack happened to be —
        // 200,000 terms was fine at `-Onone` and a segfault at `-O`, which is
        // the worst kind of limit to ship: it depends on a build setting. (The
        // same rewrite is why `unary` collects its run too.)
        var operands: [Double] = [first]
        while case .op("^")? = peek(&state) {
            state.cursor += 1
            guard let operand = unary(&state, variables, buffer)?.number else {
                setError(&state, "Expected a value after '^'")
                return nil
            }
            operands.append(operand)
            guard operands.count < maxChainDepth else {
                setError(&state, chainError)
                return nil
            }
        }
        // `2^3^2` is `2^(3^2)` — the base is raised to a chain of exponents folded
        // right-to-left, then the base goes on the outside. Folding this the
        // obvious way round (`pow(base, …)` per step) is both wrong and fatal:
        // it computes `2^2` then `2^4` then `2^16`, which is not `2^(2^(2^2))`,
        // and on a long chain it walks a value into `inf` and then asks for
        // `pow(inf, fractional)`, i.e. `nan`, i.e. a trap.
        var exponent = operands[operands.count - 1]
        for operand in operands.dropLast().reversed() {
            exponent = pow(operand, exponent)
            // `2^2^2^…` asks for intermediates no `Double` holds. Stop at the
            // first one rather than carrying an `inf` into the next `pow`, where
            // a fractional exponent turns it into `nan` and a `nan` result
            // silently fails `isFinite` checks downstream.
            guard exponent.isFinite else {
                setError(&state, "Result is too large or undefined")
                return nil
            }
        }
        let result = pow(baseNumber, exponent)
        guard result.isFinite else {
            setError(&state, "Result is too large or undefined")
            return nil
        }
        return .number(result)
    }

    private static func unary(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        // A run of `-`/`+`/`!` recurses straight back into `unary` — one frame
        // per character, and previously another way to run the stack out.
        //
        // The chain is counted in a loop rather than by recursing, because the
        // ceiling this needs is nowhere near the parser's per-level frame cost:
        // `-` × 200,000 still blew an 8 MB stack with 100,000 frames allowed,
        // so the guard has to be low enough to be safe, which makes "count the
        // operators, then apply them" the honest shape. It also fixes a plain
        // wrong answer: `1e` tokenizes as the number 1 followed by the name
        // `e`, and the old guard lived in `expression`, which a unary run never
        // re-entered.
        var operators: [UnaryOperator] = []
        loop: while true {
            switch peek(&state) {
            case .op("-"):
                state.cursor += 1
                operators.append(.negate)
            case .op("+"):
                state.cursor += 1
                operators.append(.identity)
            case .not:
                state.cursor += 1
                operators.append(.logicalNot)
            default:
                break loop
            }
            guard operators.count < maxChainDepth else {
                setError(&state, chainError)
                return nil
            }
        }
        guard let value = primary(&state, variables, buffer) else { return nil }
        guard operators.isEmpty else {
            return apply(operators, to: value, &state)
        }
        return value
    }

    /// One operator in a run of `-`/`+`/`!`. `SparkValue` would have done, but a
    /// dedicated type keeps the application loop total — no `default` arm.
    private enum UnaryOperator {
        case negate
        case identity
        case logicalNot
    }

    /// Applies a collected run outside-in, so `!!true` is `true` and `--3` is
    /// `3` — the same order the recursive form produced.
    private static func apply(
        _ operators: [UnaryOperator],
        to input: SparkValue,
        _ state: inout ParseState
    ) -> SparkValue? {
        var value = input
        for prefix in operators.reversed() {
            switch prefix {
            case .negate:
                guard let number = value.number else {
                    setError(&state, "Can't negate this")
                    return nil
                }
                value = .number(-number)
            case .identity:
                break
            case .logicalNot:
                guard let flag = value.boolean else {
                    setError(&state, "Expected a boolean after '!'")
                    return nil
                }
                value = .boolean(!flag)
            }
        }
        return value
    }

    private static func primary(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        guard let base = primaryAtom(&state, variables, buffer) else { return nil }
        return postfix(&state, variables, buffer, base: base)
    }

    private static func primaryAtom(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> SparkValue? {
        // No depth guard here: `expression` owns the ceiling, because that is
        // the frame each nesting construct re-enters. Counting in both places
        // would charge a paren twice and make the documented limit a fiction.
        switch peek(&state) {
        case .number(let value, _):
            state.cursor += 1
            return .number(value)
        case .string(let value):
            state.cursor += 1
            return .string(value)
        case .name(let name):
            state.cursor += 1
            guard case .lparen? = peek(&state) else {
                switch name {
                case "true": return .boolean(true)
                case "false": return .boolean(false)
                case "pi", "tau", "e":
                    // A user definition shadows the built-in constant. `.vars`
                    // reports `:e = 5`, so `e + 1` had better be 6 and not
                    // M_E + 1 — and it did, because the constants used to be
                    // resolved before `variables` was ever consulted.
                    // `dependencies(in:)` still excludes these names, so `:x = pi`
                    // resolves whether or not `pi` happens to be defined.
                    if let value = variables[name] { return value }
                    switch name {
                    case "pi": return .number(Double.pi)
                    case "tau": return .number(Double.pi * 2)
                    default: return .number(M_E)
                    }
                default:
                    if let value = variables[name] { return value }
                    setError(&state, "'\(name)' isn't defined")
                    return nil
                }
            }
            state.cursor += 1
            guard let args = arguments(&state, variables, buffer), !args.isEmpty else { return nil }
            return applyFunction(name, args, &state)
        case .interpolate(let inner):
            state.cursor += 1
            return resolveSubstitution(inner, &state, variables, buffer)
        case .lparen:
            state.cursor += 1
            guard let value = expression(&state, variables, buffer),
                  case .rparen? = peek(&state)
            else {
                setError(&state, "Expected ')'")
                return nil
            }
            state.cursor += 1
            return value
        case .lbracket:
            state.cursor += 1
            var items: [SparkValue] = []
            if case .rbracket? = peek(&state) {
                state.cursor += 1
                return .list([])
            }
            while true {
                guard let item = expression(&state, variables, buffer) else {
                    setError(&state, "Expected a value in the list")
                    return nil
                }
                items.append(item)
                switch peek(&state) {
                case .comma:
                    state.cursor += 1
                case .rbracket:
                    state.cursor += 1
                    return .list(items)
                default:
                    setError(&state, "Expected ',' or ']'")
                    return nil
                }
            }
        default:
            return nil
        }
    }

    /// postfix := base '[' expression ']'*
    /// Indexes into a list (or string) — `[0]` is first, `[-1]` last. Only the
    /// element is produced; chained indexes keep narrowing: `:m[0][1]`.
    private static func postfix(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?, base: SparkValue) -> SparkValue? {
        var value = base
        while case .lbracket? = peek(&state) {
            state.cursor += 1
            guard let index = expression(&state, variables, buffer) else {
                setError(&state, "Indexes need numbers")
                return nil
            }
            guard case .rbracket? = peek(&state) else {
                setError(&state, "Expected ']'")
                return nil
            }
            state.cursor += 1
            guard let raw = index.number, let offset = Int(exactly: raw) else {
                setError(&state, "Indexes need whole numbers")
                return nil
            }
            let items: [SparkValue]
            switch value {
            case .list(let list): items = list
            case .string(let string): items = string.map { .string(String($0)) }
            default:
                setError(&state, "'[' needs a list or string")
                return nil
            }
            let resolved = offset < 0 ? items.count + offset : offset
            guard resolved >= 0, resolved < items.count else {
                setError(&state, "No item \(offset) in a list of \(items.count)")
                return nil
            }
            value = items[resolved]
        }
        return value
    }

    /// Value of a `$()` span: try math first (supports `:refs` and nested
    /// substitutions), then a side-effect-free command dry-run.
    private static func resolveSubstitution(
        _ inner: String,
        _ state: inout ParseState,
        _ variables: [String: SparkValue],
        _ buffer: String?
    ) -> SparkValue? {
        // The nested parse gets a fresh `ParseState`, so the level is threaded
        // across explicitly — otherwise `$($($($(…` would reset the counter and
        // never trip any ceiling.
        if let value = evaluateValue(inner, variables: variables, buffer: buffer, depth: state.depth + 1),
           value.isFinite
        {
            return value
        }
        if let number = IntentExecution.commandDryRun(inner, buffer: buffer) {
            return .number(number)
        }
        return nil
    }

    // MARK: Function calls

    private static func arguments(_ state: inout ParseState, _ variables: [String: SparkValue], _ buffer: String?) -> [SparkValue]? {
        var args: [SparkValue] = []
        guard let first = expression(&state, variables, buffer) else { return nil }
        args.append(first)
        while case .comma? = peek(&state) {
            state.cursor += 1
            guard let next = expression(&state, variables, buffer) else { return nil }
            args.append(next)
        }
        guard case .rparen? = peek(&state) else { return nil }
        state.cursor += 1
        return args
    }

    private static let functionNames: Set<String> = [
        "sqrt", "abs", "round", "min", "max", "len", "upper", "lower",
        "sin", "cos", "tan", "asin", "acos", "atan",
        "ln", "log", "exp", "floor", "ceil", "sign",
    ]

    /// The most entries `a..b` may expand to. Exceeding it is an error rather
    /// than a truncated range: a silently shortened list would be a wrong
    /// answer committed to the note.
    private static let rangeCap = 100_000

    /// How deeply an expression may nest — parentheses, list brackets, `$( )`
    /// spans — before the parser gives up. This is the number a person means by
    /// "nested too deeply", and it counts those constructs and nothing else.
    ///
    /// Sized against the *cost of a frame*, not by feel. One level of nesting is
    /// ~11 stack frames (`expression`, `orExpression`, `andExpression`,
    /// `equality`, `comparison`, `range`, `additive`, `term`, `power`, `unary`,
    /// `primary`), and in a Debug build — which is what the test runner uses —
    /// those frames are several times larger than in release. 64 levels is ~700
    /// frames, which overflows the 512 KB stack the test host hands a thread
    /// and killed `xctest` even though every standalone check passed. 24 levels
    /// is ~260 frames: past anything written by hand by a wide margin, and
    /// comfortable in a small stack in either build.
    ///
    /// If this is ever raised, re-check it against a Debug build on a small
    /// `Thread.stackSize` rather than assuming release-build headroom applies.
    private static let maxNestingDepth = 24

    /// The ceiling on *operator chains* instead: right-associative `^` recurses
    /// through `power`, one frame per operator. Those are bounded by line length
    /// rather than by nesting, so they get their own, far larger allowance.
    ///
    /// Kept separate from `maxNestingDepth` on purpose: sharing one counter made
    /// the nesting limit meaningless, since each parenthesis also costs a
    /// `power` and a `unary` frame, so a documented "64 deep" behaved like 20.
    private static let maxChainDepth = 4_096

    /// Flattens nested lists into their numbers, so `min([1, 2], 3)` and
    /// `max(1..5)` behave like their multi-argument forms.
    private static func flattenNumbers(_ values: [SparkValue]) -> [Double] {
        values.flatMap { numbers(from: $0) }
    }

    /// Every number inside a value, recursing through nested lists; strings
    /// and booleans contribute nothing. Shared with aggregate arguments so
    /// `.sum :items` and `.sum 1..10` flatten the same way.
    static func numbers(from value: SparkValue) -> [Double] {
        switch value {
        case .number(let n): [n]
        case .list(let items): items.flatMap { numbers(from: $0) }
        default: []
        }
    }

    private static func applyFunction(_ name: String, _ args: [SparkValue], _ state: inout ParseState) -> SparkValue? {
        let numbers = flattenNumbers(args)
        let allNumbers = args.allSatisfy { $0.number != nil || $0.isList }
        switch name {
        case "sqrt":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(sqrt(numbers[0]))
        case "abs":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(abs(numbers[0]))
        case "round":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(numbers[0].rounded())
        case "floor":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(numbers[0].rounded(.down))
        case "ceil":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(numbers[0].rounded(.up))
        case "sign":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(numbers[0] > 0 ? 1 : (numbers[0] < 0 ? -1 : 0))
        case "sin":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(sin(numbers[0]))
        case "cos":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(cos(numbers[0]))
        case "tan":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(tan(numbers[0]))
        case "asin":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(asin(numbers[0]))
        case "acos":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(acos(numbers[0]))
        case "atan":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(atan(numbers[0]))
        case "ln":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(numbers[0] > 0 ? log(numbers[0]) : .nan)
        case "log":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(numbers[0] > 0 ? log10(numbers[0]) : .nan)
        case "exp":
            guard allNumbers, numbers.count == 1 else { break }
            return .number(pow(M_E, numbers[0]))
        case "min":
            guard allNumbers, !numbers.isEmpty else { break }
            return .number(numbers.min() ?? 0)
        case "max":
            guard allNumbers, !numbers.isEmpty else { break }
            return .number(numbers.max() ?? 0)
        case "len":
            guard args.count == 1 else { break }
            if let string = args[0].string { return .number(Double(string.count)) }
            if let list = args[0].list { return .number(Double(list.count)) }
            break
        case "upper":
            guard args.count == 1, let string = args[0].string else { break }
            return .string(string.uppercased())
        case "lower":
            guard args.count == 1, let string = args[0].string else { break }
            return .string(string.lowercased())
        default:
            setError(&state, "Unknown function '\(name)'")
            return nil
        }
        if functionNames.contains(name) {
            setError(&state, "'\(name)' got the wrong arguments")
        } else {
            setError(&state, "Unknown function '\(name)'")
        }
        return nil
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

    /// How many `$(` spans are open at the deepest point of `input`. A linear
    /// scan: no recursion, no allocation — cheap enough to run on every parse.
    ///
    /// This is what makes the `$()` ceiling enforceable. A span is a *single*
    /// token however deeply it nests, so the parser can only learn the depth by
    /// recursing into it, which is exactly what exhausts the stack. Parens and
    /// brackets don't have that problem — they're separate tokens, and the
    /// per-level check inside `expression` bounds them as they're entered — so
    /// this count is the one that has to be known up front.
    private static func spanNestingDepth(of input: String) -> Int {
        let ns = input as NSString
        var deepest = 0
        var index = 0
        var open = 0
        while index < ns.length {
            switch ns.character(at: index) {
            case 36 where index + 1 < ns.length && ns.character(at: index + 1) == 40:
                open += 1
                deepest = max(deepest, open)
                index += 2 // skip the '(' so it can't also count as a plain paren
            case 41:
                open = max(0, open - 1)
                index += 1
            default:
                index += 1
            }
        }
        return deepest
    }

    /// A token as the user wrote it, *unquoted* — the caller supplies the quotes.
    /// These used to come back pre-quoted (`"')'"`), and the one call site wraps
    /// them again, so every unexpected-token message read `Unexpected '')''`,
    /// `Unexpected ''e''`, `Unexpected '']''`.
    private static func describeToken(_ token: Token) -> String {
        switch token {
        case .number(_, let source): source
        case .op(let op): op
        case .name(let name): name
        case .interpolate(let inner): "$(\(inner))"
        case .string(let value): "\"\(value)\""
        case .lparen: "("
        case .rparen: ")"
        case .lbracket: "["
        case .rbracket: "]"
        case .comma: ","
        case .not: "!"
        case .invalid(let text): text
        }
    }
}