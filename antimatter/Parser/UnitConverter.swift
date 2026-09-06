import Foundation

/// Unit conversion: physical units from a built-in offline table
/// (`12 kg → lb`, `3 mi -> km`, `100 °F -> c`), plus — only when the opt-in
/// network switch is on — currency and cryptocurrency conversion using
/// Coinbase's cached rates (`100 USD -> EUR`, `1 btc → usd`). The line is
/// rewritten to include the answer: `12 kg → lb = 26.46`.
nonisolated enum UnitConverter {
    /// Base-unit factors per dimension; conversion requires matching dimensions.
    private static let linearUnits: [String: (dimension: String, factor: Double)] = [
        // length, base metre
        "mm": ("length", 0.001), "cm": ("length", 0.01), "m": ("length", 1),
        "km": ("length", 1_000), "in": ("length", 0.0254), "ft": ("length", 0.3048),
        "yd": ("length", 0.9144), "mi": ("length", 1_609.344),
        // mass, base kilogram
        "mg": ("mass", 0.000_001), "g": ("mass", 0.001), "kg": ("mass", 1),
        "oz": ("mass", 0.028_349_523_125), "lb": ("mass", 0.453_592_37),
    ]

    /// Characters treated as a conversion arrow: `→`, the digraph `->`, and
    /// the en/em dashes `–`/`—` (typed `--`/`---` become those dashes, so a
    /// conversion can be written with plain hyphens too).
    private static let arrows: Set<String> = ["→", "->", "–", "—", "—-", "—>"]

    static func commit(_ rawLine: String) -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (value, fromName, toName) = parse(trimmed),
              let converted = convert(value: value, from: fromName, to: toName)
        else { return nil }
        let indent = String(rawLine.prefix(while: { $0 == " " || $0 == "\t" }))
        return indent + trimmed + " = " + format(converted)
    }

    static func convert(value: Double, from: String, to: String) -> Double? {
        let fromUnit = from.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "°"))
        let toUnit = to.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "°"))
        if isTemperature(fromUnit), isTemperature(toUnit) {
            return convertTemperature(value, fromUnit, toUnit)
        }
        if isPhysical(fromUnit), isPhysical(toUnit) {
            guard let source = linearUnits[fromUnit], let target = linearUnits[toUnit],
                  source.dimension == target.dimension
            else { return nil }
            return value * source.factor / target.factor
        }
        // Currency pairs only ever convert when the opt-in network feed has a
        // cached rate for both symbols; a physical unit never collides with a
        // currency code we care about.
        return CurrencyCenter.convert(value: value, from: fromUnit, to: toUnit)
    }

    private static func isPhysical(_ unit: String) -> Bool {
        linearUnits[unit] != nil
    }

    // MARK: Parsing

    /// `<number> <unit> <arrow> <unit>` — arrow may be `→`, `->`, or the
    /// en/em dashes `–`/`—`; a bare `>` is deliberately not an arrow, so
    /// comparison-shaped lines stay text.
    static func parse(_ line: String) -> (value: Double, from: String, to: String)? {
        let words = splitPreservingArrow(line)
        guard words.count == 4,
              let value = Double(words[0])
        else { return nil }
        let arrow = words[2]
        guard arrows.contains(arrow) else { return nil }
        return (value, words[1], words[3])
    }

    private static func splitPreservingArrow(_ line: String) -> [String] {
        // Arrows can sit flush against their operand (`12 kg->lb`, `12kg→lb`)
        // or be surrounded by spaces, so find the first arrow and split the
        // line around it rather than relying on `" "` separation.
        var earliest: (lower: String.Index, upper: String.Index)? = nil
        for arrow in arrows {
            if let range = line.range(of: arrow) {
                if earliest == nil || range.lowerBound < earliest!.lower {
                    earliest = (range.lowerBound, range.upperBound)
                }
            }
        }
        guard let arrowRange = earliest else {
            return line.components(separatedBy: " ").filter { !$0.isEmpty }
        }
        let before = line[..<arrowRange.lower]
            .components(separatedBy: " ").filter { !$0.isEmpty }
        let arrowString = String(line[arrowRange.lower..<arrowRange.upper])
        let after = line[arrowRange.upper...]
            .components(separatedBy: " ").filter { !$0.isEmpty }
        return before + [arrowString] + after
    }

    // MARK: Temperature

    private static func isTemperature(_ unit: String) -> Bool {
        unit == "c" || unit == "f" || unit == "k"
    }

    private static func convertTemperature(_ value: Double, _ from: String, _ to: String) -> Double? {
        func toCelsius(_ v: Double, _ unit: String) -> Double {
            switch unit {
            case "f": (v - 32) * 5 / 9
            case "k": v - 273.15
            default: v
            }
        }
        func fromCelsius(_ c: Double, _ unit: String) -> Double {
            switch unit {
            case "f": c * 9 / 5 + 32
            case "k": c + 273.15
            default: c
            }
        }
        let celsius = toCelsius(value, from)
        return fromCelsius(celsius, to)
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.6g", value)
    }
}
