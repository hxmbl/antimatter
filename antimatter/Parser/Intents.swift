import Foundation

nonisolated enum IntentParser {
    struct Timer: Equatable {
        let duration: TimeInterval
        let label: String
        let name: String?
        let fullScreen: Bool
        /// True when the requested duration exceeded the cap and was shortened.
        var clamped = false
    }


    static let commandPrefix = "."

    struct Calculation: Equatable {
        let expression: String
        let result: Double
    }


    static func parseTimer(_ line: String) -> Timer? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.first?.lowercased() == commandPrefix + "timer" else { return nil }

        var duration: TimeInterval = 0
        var matchedAny = false
        var index = 1
        while index < words.count {
            // "5 mins", "90 minutes", "2.5 h" — number and unit as separate words.
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

    static let maxDuration: TimeInterval = 60 * 60 * 24 * 30

    static func isTimerCancel(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == commandPrefix + "timer cancel"
            || trimmed == commandPrefix + "timer cancel all"
    }


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

    /// Anything shaped like `2026-08-22` or `8-22` never auto-calculates.
    static func looksLikeDate(_ input: String) -> Bool {
        input.range(of: #"\d{1,4}-\d{1,2}-\d{1,4}"#, options: .regularExpression) != nil
            || input.range(of: #"\b\d{1,2}-\d{1,2}\b"#, options: .regularExpression) != nil
    }

     static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
