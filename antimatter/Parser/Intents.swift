import Foundation

/// Detects executable intents on a single line. Everything that does not
/// parse stays ordinary text — only recognised commands do anything.
///
/// Dot-commands are explicit: `.timer 5`, `.timer 90s`, `.timer 1h 20m stand up`
/// (a bare number means minutes, per the README). A plain word like `timer`
/// in a note is just a word.
///
/// Calculations need no command at all — they happen automatically:
/// * typing `=` after an expression (`384 * 27 =`) asks for the answer
///   immediately — explicit intent wins even over the date heuristic;
/// * pressing return on a line that is pure arithmetic rewrites it to
///   `expression = result`. Lines shaped like dates (`2026-08-22`) are
///   excluded so notes stay notes.
nonisolated enum IntentParser {
    struct Timer: Equatable {
        let duration: TimeInterval
        let label: String
        /// True when the requested duration exceeded the cap and was
        /// shortened — surfaced to the user as a transient notice.
        var clamped = false
    }

    /// The dot-command prefix; commands must be typed, not stumbled into.
    static let commandPrefix = "."

    struct Calculation: Equatable {
        let expression: String
        let result: Double
    }

    // MARK: Timers

    static func parseTimer(_ line: String) -> Timer? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.first?.lowercased() == commandPrefix + "timer" else { return nil }

        var duration: TimeInterval = 0
        var matchedAny = false
        var index = 1
        while index < words.count, let (value, unit) = durationToken(words[index]) {
            duration += value * unit.seconds
            matchedAny = true
            index += 1
        }
        guard matchedAny, duration > 0 else { return nil }

        let label = index < words.count ? words[index...].joined(separator: " ") : ""
        let capped = duration > maxDuration
        return Timer(duration: min(duration, maxDuration), label: label, clamped: capped)
    }

    /// Largest supported timer: 30 days.
    static let maxDuration: TimeInterval = 60 * 60 * 24 * 30

    private static func durationToken(_ word: String) -> (value: Double, unit: DurationUnit)? {
        let digits = word.prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") })
        guard let value = Double(digits), digits.contains(where: \.isNumber), !word.isEmpty else { return nil }
        let suffix = String(word.dropFirst(digits.count)).lowercased()
        guard let unit = DurationUnit(rawValue: suffix) ?? (suffix.isEmpty ? .minutes : nil) else { return nil }
        return (value, unit)
    }

    private enum DurationUnit {
        case milliseconds
        case seconds
        case minutes
        case hours
        case days

        var seconds: TimeInterval {
            switch self {
            case .milliseconds: 0.001
            case .seconds: 1
            case .minutes: 60
            case .hours: 3_600
            case .days: 86_400
            }
        }

        init?(rawValue: String) {
            switch rawValue {
            case "ms": self = .milliseconds
            case "s": self = .seconds
            case "m": self = .minutes
            case "h": self = .hours
            case "d": self = .days
            default: return nil
            }
        }
    }

    // MARK: Calculations

    /// The typed-equals commit form: the line ends with `=`.
    static func pendingCalculation(_ line: String) -> Calculation? {
        guard line.hasSuffix("=") else { return nil }
        let expression = line.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, let result = ExpressionEvaluator.evaluate(expression) else { return nil }
        // Skip pointless identity rewrites like `-5 =`.
        guard format(result) != expression else { return nil }
        return Calculation(expression: expression, result: result)
    }

    /// The whole-line arithmetic form used when return is pressed.
    static func parseCalculation(_ line: String) -> Calculation? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !looksLikeDate(trimmed),
              let result = ExpressionEvaluator.evaluate(trimmed),
              format(result) != trimmed
        else { return nil }
        return Calculation(expression: trimmed, result: result)
    }

    /// Guards note-taking: anything shaped like `2026-08-22` or `8-22`
    /// never auto-calculates, no matter how valid the arithmetic would be.
    /// Only tight numeric shapes count — spaced dashes (`100 - 25`) are
    /// ordinary subtraction, not dates.
    static func looksLikeDate(_ input: String) -> Bool {
        input.range(of: #"\d{1,4}-\d{1,2}-\d{1,4}"#, options: .regularExpression) != nil
            || input.range(of: #"\b\d{1,2}-\d{1,2}\b"#, options: .regularExpression) != nil
    }

    /// Locale-independent result formatting: integers stay integers,
    /// everything else keeps up to 12 significant digits without noise.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.12g", value)
    }
}
