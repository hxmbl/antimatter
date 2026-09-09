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
        let name: String?
        let fullScreen: Bool
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
        while index < words.count {
            // "5 mins", "90 minutes", "2.5 h" — number and unit as separate
            // words. Checked first so a bare number followed by a spelled-out
            // unit is not eaten as "5 minutes" with the unit left labelled.
            if let value = bareNumber(words[index]),
               index + 1 < words.count,
               let unit = DurationUnit(words[index + 1])
            {
                duration += value * unit.seconds
                matchedAny = true
                index += 2
            } else if let (value, unit) = durationToken(words[index]) {
                duration += value * unit.seconds
                matchedAny = true
                index += 1
            } else {
                break
            }
        }
        guard matchedAny, duration > 0 else { return nil }

        let remaining = index < words.count ? words[index...] : []
        let lowercased = remaining.joined(separator: " ").lowercased()
        let fullScreen = lowercased.contains("full-screen")

        var labelParts: [String] = []
        var name: String?
        var i = 0
        let remainingArray = Array(remaining)
        while i < remainingArray.count {
            let word = remainingArray[i]
            if word.lowercased() == "name" && i + 1 < remainingArray.count {
                name = remainingArray[(i + 1)...].joined(separator: " ")
                break
            }
            if word.lowercased() == "full-screen" {
                i += 1
                continue
            }
            labelParts.append(word)
            i += 1
        }
        let label = labelParts.joined(separator: " ")
        let capped = duration > maxDuration
        return Timer(duration: min(duration, maxDuration), label: label, name: name, fullScreen: fullScreen, clamped: capped)
    }

    /// Largest supported timer: 30 days.
    static let maxDuration: TimeInterval = 60 * 60 * 24 * 30

    /// `.timer cancel` / `.timer cancel all` — cancel every running timer.
    static func isTimerCancel(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == commandPrefix + "timer cancel"
            || trimmed == commandPrefix + "timer cancel all"
    }

    // MARK: Pomodoro

    struct Pomodoro: Equatable {
        let workDuration: TimeInterval
        let breakDuration: TimeInterval
        let cycles: Int
    }

    static func parsePomodoro(_ line: String) -> Pomodoro? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(commandPrefix + "pomodoro") else { return nil }
        let rest = String(trimmed.dropFirst((commandPrefix + "pomodoro").count))
            .trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2,
              let workMin = Double(parts[0]),
              let breakMin = Double(parts[1])
        else { return nil }
        let cycles = parts.count >= 3 ? (Int(parts[2]) ?? 4) : 4
        return Pomodoro(workDuration: workMin * 60, breakDuration: breakMin * 60, cycles: min(cycles, 12))
    }

    // MARK: Stopwatches

    /// `.stopwatch` starts a stopwatch counting up; anything after the
    /// command becomes its label. `.stopwatch cancel [all]` clears them.
    static func isStopwatch(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == commandPrefix + "stopwatch"
            || trimmed.hasPrefix(commandPrefix + "stopwatch ")
    }

    static func isStopwatchCancel(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == commandPrefix + "stopwatch cancel"
            || trimmed == commandPrefix + "stopwatch cancel all"
    }

    /// Everything after `.stopwatch ` — the labelled remainder. Empty for a
    /// bare `.stopwatch`.
    static func stopwatchLabel(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = commandPrefix + "stopwatch"
        guard trimmed.lowercased().hasPrefix(prefix) else { return "" }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func bareNumber(_ word: String) -> Double? {
        guard !word.isEmpty,
              word.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              word.contains(where: \.isNumber)
        else { return nil }
        return Double(word)
    }

    private static func durationToken(_ word: String) -> (value: Double, unit: DurationUnit)? {
        let digits = word.prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") })
        guard let value = Double(digits), digits.contains(where: \.isNumber), !word.isEmpty else { return nil }
        let suffix = String(word.dropFirst(digits.count)).lowercased()
        if suffix.isEmpty { return (value, .minutes) }
        guard let unit = DurationUnit(suffix) else { return nil }
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

        /// Full words and abbreviations; case-insensitive.
        init?(_ rawValue: String) {
            switch rawValue.lowercased() {
            case "ms", "millisecond", "milliseconds": self = .milliseconds
            case "s", "sec", "secs", "second", "seconds": self = .seconds
            case "m", "min", "mins", "minute", "minutes": self = .minutes
            case "h", "hr", "hrs", "hour", "hours": self = .hours
            case "d", "day", "days": self = .days
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
        // Bare numbers never rewrite: `1.` is a list marker, not a calculation.
        guard !ExpressionEvaluator.isBareNumber(expression) else { return nil }
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
        // Bare numbers (e.g. `1.`, `42`) never auto-rewrite on return.
        guard !ExpressionEvaluator.isBareNumber(trimmed) else { return nil }
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
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
