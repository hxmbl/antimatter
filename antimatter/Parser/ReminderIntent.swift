import Foundation

/// Natural-language reminders: `.remind me in 10 minutes to stand up`.
/// Uses NSDataDetector for calendar language and a hand-rolled matcher for
/// relative time ("in 10 minutes", "in 1h").
nonisolated enum ReminderIntent {
    struct Reminder: Equatable {
        let date: Date
        let message: String
    }

    static let command = IntentParser.commandPrefix + "remind"

    /// `.reminder cancel [all]` — cancel every active reminder.
    static func isCancelAll(_ rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == IntentParser.commandPrefix + "reminder cancel"
            || trimmed == IntentParser.commandPrefix + "reminder cancel all"
            || trimmed == IntentParser.commandPrefix + "remind cancel"
            || trimmed == IntentParser.commandPrefix + "remind cancel all"
    }

    static func parse(_ rawLine: String, now: Date = Date()) -> Reminder? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(command) else { return nil }
        let rest = String(trimmed.dropFirst(command.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        var date: Date?
        var remainder = rest

        if let (relative, after) = relativeTime(in: rest, now: now) {
            date = relative
            remainder = String(rest[after...])
        } else if let (absolute, after) = absoluteTime(in: rest) {
            date = absolute
            remainder = String(rest[after...])
        }

        let message = extractMessage(from: remainder)
        guard let date, !message.isEmpty else { return nil }
        return Reminder(date: date, message: message)
    }


    private static let relativePattern = regex(
        #"in\s+(a|an|one|(\d+(?:\.\d+)?))\s*(milliseconds?|ms|seconds?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d)"#
    )
    private static let bareMinutesPattern = regex(#"^in\s+(\d+)\s*$"#)

    private static func relativeTime(in text: String, now: Date) -> (Date, String.Index)? {
        if let match = relativePattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text)
        {
            let unit = (match.numberOfRanges > 3
                ? Range(match.range(at: 3), in: text).map { text[$0].lowercased() }
                : nil) ?? ""
            let seconds = unitSeconds[unit] ?? 60
            var amount = 1.0
            if match.numberOfRanges > 2,
               let amountRange = Range(match.range(at: 2), in: text),
               let value = Double(text[amountRange])
            {
                amount = value
            }
            return (now.addingTimeInterval(amount * seconds), range.upperBound)
        }
        if let match = bareMinutesPattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let valueRange = Range(match.range(at: 1), in: text),
           let value = Double(text[valueRange]),
           let whole = Range(match.range, in: text)
        {
            return (now.addingTimeInterval(value * 60), whole.upperBound)
        }
        return nil
    }


    private static func absoluteTime(in text: String) -> (Date, String.Index)? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        guard let detector else { return nil }
        let matches = detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        guard let match = matches.first(where: { $0.resultType == .date }),
              let date = match.date,
              let range = Range(match.range, in: text)
        else { return nil }
        return (date, range.upperBound)
    }


    private static func extractMessage(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Quoted messages are verbatim (quotes stripped).
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] where trimmed.hasPrefix(open) {
            if trimmed.count > 1, trimmed.hasSuffix(close) {
                return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // "to X" / "about X" glue is dropped.
        let words = trimmed.split(separator: " ", maxSplits: 1)
        if let first = words.first, (first == "to" || first == "about"), words.count > 1 {
            return String(words[1])
        }
        return trimmed
    }

    private static let unitSeconds: [String: TimeInterval] = [
        "millisecond": 0.001, "milliseconds": 0.001, "ms": 0.001,
        "second": 1, "seconds": 1, "s": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60, "m": 60,
        "hour": 3_600, "hours": 3_600, "hr": 3_600, "hrs": 3_600, "h": 3_600,
        "day": 86_400, "days": 86_400, "d": 86_400,
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))!
    }
}