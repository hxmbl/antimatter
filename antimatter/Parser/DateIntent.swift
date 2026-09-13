import Foundation

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

     static func parseISO(_ input: String) -> DateComponents? {
         // Strict shape first: loose forms like `2026-8-22` must stay text.
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

/// `.time` stamps the current wall-clock time onto a line: pressing return on
/// `.time` rewrites it to `.time = 2:31 PM`. Deterministic for tests via `now`.
nonisolated enum TimeIntent {
    /// The exact stamp used: `h:mm a` in en_US_POSIX so AM/PM tokens never
    /// depend on the host locale, but in the user's own time zone.
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func commit(_ rawLine: String, now: Date = Date()) -> String {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let indent = String(rawLine.prefix(while: { $0 == " " || $0 == "\t" }))
        return indent + trimmed + " = " + format(now)
    }

    /// Numeric form for `$()` substitution: the clock time as a decimal
    /// `HH.MM` in 24-hour form, e.g. 11:11 → 11.11, 2:05 → 14.05.
    static func numeric(_ date: Date = Date(), calendar: Calendar = .current) -> Double {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return Double(hour) + Double(minute) / 100
    }
}
