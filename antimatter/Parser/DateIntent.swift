import Foundation

/// Date-shaped lines become answers instead of staying inert text.
///
/// * A bare ISO date (`2026-08-22`) quietly gains its weekday:
///   `2026-08-22 · Saturday`.
/// * `days until 2026-09-01` gains the day count from today:
///   `days until 2026-09-01 = 8`.
///
/// Only strict `YYYY-MM-DD` counts; loose shapes like `8-22` remain
/// ordinary text (and are still excluded from auto-calculation).
nonisolated enum DateIntent {
    static func commit(
        _ rawLine: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = parseISO(trimmed) {
            let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
            return indentPrefix(of: rawLine) + trimmed + " · " + weekday
        }
        if trimmed.lowercased().hasPrefix("days until ") {
            let token = String(trimmed.dropFirst("days until ".count))
                .trimmingCharacters(in: .whitespaces)
            guard let target = parseISO(token) else { return nil }
            let startOfToday = calendar.startOfDay(for: now)
            let startOfTarget = calendar.startOfDay(for: target)
            let days = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget).day ?? 0
            return indentPrefix(of: rawLine) + trimmed + " = " + String(days)
        }
        return nil
    }

    static func parseISO(_ input: String) -> Date? {
        // Strict shape first: the formatter alone accepts loose forms like
        // `2026-8-22`, which must stay ordinary text.
        guard input.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: input)
    }

    private static func indentPrefix(of rawLine: String) -> String {
        String(rawLine.prefix(while: { $0 == " " || $0 == "\t" }))
    }
}
