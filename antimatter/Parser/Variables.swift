import Foundation

/// Variable definitions and whole-note aggregation. Definitions are
/// `name = expression` lines; later definitions win, forward references stay text.
nonisolated enum VariableTable {
    static func scan(_ text: String) -> [String: Double] {
        var table: [String: Double] = [:]
        let ns = text as NSString
        for lineRange in lineRanges(ns) {
            let trimmed = ns.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (name, rhs) = splitDefinition(trimmed),
                  let value = ExpressionEvaluator.evaluate(rhs, variables: table)
            else { continue }
            table[name] = value
        }
        return table
    }

    /// Splits `name = expression`, validating the identifier shape.
    static func splitDefinition(_ trimmedLine: String) -> (name: String, expression: String)? {
        guard let separator = trimmedLine.range(of: " = ") else { return nil }
        let name = String(trimmedLine[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let rhs = String(trimmedLine[separator.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard isIdentifier(name), !rhs.isEmpty else { return nil }
        return (name.lowercased(), rhs)
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
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
            if let (_, rhs) = VariableTable.splitDefinition(trimmed) {
                candidate = mathCore(ofCommittedLine: rhs) ?? rhs
            } else {
                candidate = mathCore(ofCommittedLine: trimmed) ?? trimmed
            }
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
