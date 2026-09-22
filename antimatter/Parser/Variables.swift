import Foundation

/// Variable definitions and whole-note aggregation. Definitions are
/// `:name = expression` lines. Later definitions win; forward references
/// resolve in dependency order; a bare `:name =` undefines the variable;
/// self-references and circular definitions stay text.
nonisolated enum VariableTable {
    /// A stored binding in document order: either a definition with an
    /// expression, or a deletion that removes the name.
    private enum Binding {
        case define(name: String, rhs: String)
        case unset(name: String)
    }

    /// Resolves the note's definitions into a `name → value` table. Values can
    /// be numbers, booleans, strings, or lists.
    static func scan(_ text: String) -> [String: SparkValue] {
        resolve(text).table
    }

    /// Definitions that could not resolve (self-references, circular loops,
    /// or undefined dependencies), in document order. Used for diagnostics.
    static func unresolvedDefinitions(in text: String) -> [(name: String, rhs: String)] {
        resolve(text).unresolved
    }

    /// Names caught in a circular dependency (a loop of definitions that each
    /// depend on another in the loop). Pure self-references are excluded —
    /// they're reported as such, not as a cycle.
    static func circularDependencies(in text: String) -> [String] {
        var graph: [String: Set<String>] = [:]
        for definition in unresolvedDefinitions(in: text) {
            let deps = ExpressionEvaluator.dependencies(in: definition.rhs)
            graph[definition.name, default: []].formUnion(deps.filter { $0 != definition.name })
        }
        guard !graph.isEmpty else { return [] }

        var visited: Set<String> = []
        var inStack: Set<String> = []
        var stack: [String] = []
        var cyclic: Set<String> = []

        func dfs(_ node: String) {
            if inStack.contains(node) {
                if let start = stack.firstIndex(of: node) {
                    for member in stack[start...] { cyclic.insert(member) }
                }
                return
            }
            guard visited.insert(node).inserted else { return }
            inStack.insert(node)
            stack.append(node)
            for dep in graph[node] ?? [] {
                if graph[dep] != nil { dfs(dep) }
            }
            stack.removeLast()
            inStack.remove(node)
        }
        for node in graph.keys { dfs(node) }
        return cyclic.sorted()
    }

    // MARK: Resolution

    /// Repeated passes over the bindings. A definition lands once its
    /// dependencies are all in the table, so forward references and chains
    /// resolve whatever order they appear in. Deletions always land in the
    /// first pass at their document position. Anything still unmet at the end
    /// (self-reference, cycle, unknown name) stays text.
    private static func resolve(_ text: String) -> (table: [String: SparkValue], unresolved: [(name: String, rhs: String)]) {
        var bindings: [Binding] = []
        for lineRange in lineRanges(text as NSString) {
            let trimmed = (text as NSString).substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let (name, rhs) = splitDefinition(trimmed) {
                bindings.append(.define(name: name, rhs: rhs))
            } else if let name = unsetDefinition(trimmed) {
                bindings.append(.unset(name: name))
            }
        }

        var table: [String: SparkValue] = [:]
        var resolved: Set<Int> = []
        var progress = true
        while progress {
            progress = false
            for (index, binding) in bindings.enumerated() where !resolved.contains(index) {
                switch binding {
                case .unset(let name):
                    table[name] = nil
                    resolved.insert(index)
                    progress = true
                case .define(let name, let rhs):
                    let deps = ExpressionEvaluator.dependencies(in: rhs)
                    guard deps.allSatisfy({ table[$0] != nil }) else { continue }
                    guard let value = ExpressionEvaluator.evaluateValue(rhs, variables: table, buffer: text),
                          value.isFinite
                    else { continue }
                    table[name] = value
                    resolved.insert(index)
                    progress = true
                }
            }
        }

        var unresolved: [(name: String, rhs: String)] = []
        for (index, binding) in bindings.enumerated() where !resolved.contains(index) {
            if case .define(let name, let rhs) = binding {
                unresolved.append((name, rhs))
            }
        }
        return (table, unresolved)
    }

    /// Splits an explicit `:name = expression` definition.
    static func splitDefinition(_ trimmedLine: String) -> (name: String, expression: String)? {
        guard let separator = trimmedLine.range(of: " = ") else { return nil }
        var name = String(trimmedLine[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let rhs = String(trimmedLine[separator.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix(":") else { return nil }
        name.removeFirst()
        guard isIdentifier(name), !rhs.isEmpty else { return nil }
        return (name.lowercased(), rhs)
    }

    /// Splits a deletion `:name =` (with nothing after the equals). The
    /// variable stops being defined from this line onward.
    static func unsetDefinition(_ trimmedLine: String) -> String? {
        let parts = trimmedLine.components(separatedBy: "=")
        guard parts.count == 2,
              parts[1].trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        guard name.hasPrefix(":"), name.count > 1 else { return nil }
        let bare = String(name.dropFirst())
        guard isIdentifier(bare) else { return nil }
        return bare.lowercased()
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func arithmeticDefinition(_ line: String) -> (name: String, expression: String)? {
        if let definition = splitDefinition(line) {
            return definition
        }
        guard let separator = line.range(of: " = ") else { return nil }
        let name = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let expression = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard isIdentifier(name), !expression.isEmpty else { return nil }
        return (name, expression)
    }

    static func lineRanges(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }
}

/// Collects the note's numbers for `.sum` / `.avg` / `.count`.
/// A line contributes only when it's arithmetic; prose, timers, and dates contribute nothing.
nonisolated enum Aggregates {
    static func numbers(in text: String) -> [Double] {
        var collected: [Double] = []
        let ns = text as NSString
        for lineRange in VariableTable.lineRanges(ns) {
            let trimmed = ns.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if IntentParser.looksLikeDate(trimmed) { continue }
            // Definitions contribute their right-hand side (with any stored
            // result stripped); other lines contribute themselves minus a
            // trailing committed answer.
            let candidate: String
            if let (_, rhs) = VariableTable.arithmeticDefinition(trimmed) {
                candidate = mathCore(ofCommittedLine: rhs) ?? rhs
            } else {
                candidate = mathCore(ofCommittedLine: trimmed) ?? trimmed
            }
            // A whole-note substitution such as `$(.sum)` must not count the
            // definition currently being scanned and recurse into itself.
            if candidate.contains("$(") { continue }
            guard !candidate.isEmpty,
                  let literals = ExpressionEvaluator.numericLiterals(candidate)
            else { continue }
            collected.append(contentsOf: literals)
        }
        return collected
    }

    /// For `expr = number` returns the expression part with any assignment
    /// prefix (`name =`) already removed.
    private static func mathCore(ofCommittedLine line: String) -> String? {
        let parts = line.components(separatedBy: " = ")
        guard parts.count >= 2,
              let result = parts.last,
              Double(result.trimmingCharacters(in: .whitespaces)) != nil
        else { return nil }
        var core = parts.dropLast().joined(separator: " = ")
        if let separator = core.range(of: "=") {
            let name = String(core[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if VariableTable.isIdentifier(name) {
                core = core[core.index(after: separator.lowerBound)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return core.isEmpty ? nil : core
    }
}