import Foundation

/// Date-shaped lines become answers instead of staying inert text.
///
/// * A bare ISO date (`2026-08-22`) quietly gains its weekday:
///   `2026-08-22 = Saturday`.
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
        if let components = parseISO(trimmed), let date = calendar.date(from: components) {
            let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
            return indentPrefix(of: rawLine) + trimmed + " = " + weekday
        }
        if trimmed.lowercased().hasPrefix("days until ") {
            let token = String(trimmed.dropFirst("days until ".count))
                .trimmingCharacters(in: .whitespaces)
            guard let components = parseISO(token), let target = calendar.date(from: components) else { return nil }
            let startOfToday = calendar.startOfDay(for: now)
            let startOfTarget = calendar.startOfDay(for: target)
            let days = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget).day ?? 0
            return indentPrefix(of: rawLine) + trimmed + " = " + String(days)
        }
        return nil
    }

    /// Splits strict `YYYY-MM-DD` into calendar components. The date is
    /// interpreted only later, in the caller's own calendar, so a figure
    /// like `2026-08-22` keeps its weekday regardless of the user's
    /// timezone — a UTC-midnight instant would otherwise show the previous
    /// day's weekday in every zone west of GMT.
    static func parseISO(_ input: String) -> DateComponents? {
        // Strict shape first: the components alone accept loose forms like
        // `2026-8-22`, which must stay ordinary text.
        guard input.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = input.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    private static func indentPrefix(of rawLine: String) -> String {
        String(rawLine.prefix(while: { $0 == " " || $0 == "\t" }))
    }
}
