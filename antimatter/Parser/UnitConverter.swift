import Foundation

/// Offline unit conversion from a built-in table: `12 kg → lb`,
/// `3 mi -> km`, `100 °F -> c`. No network, ever. The line is rewritten to
/// include the answer: `12 kg → lb = 26.46`.
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
        guard let source = linearUnits[fromUnit], let target = linearUnits[toUnit],
              source.dimension == target.dimension
        else { return nil }
        return value * source.factor / target.factor
    }

    // MARK: Parsing

    /// `<number> <unit> → <unit>` — arrow may be `→` or `->`; a bare `>`
    /// is deliberately not an arrow, so comparison-shaped lines stay text.
    static func parse(_ line: String) -> (value: Double, from: String, to: String)? {
        let words = splitPreservingArrow(line)
        guard words.count == 4,
              let value = Double(words[0])
        else { return nil }
        let arrow = words[2]
        guard arrow == "→" || arrow == "->" else { return nil }
        return (value, words[1], words[3])
    }

    private static func splitPreservingArrow(_ line: String) -> [String] {
        if line.contains("→") {
            return line.components(separatedBy: " ").filter { !$0.isEmpty }
        }
        if let range = line.range(of: "->") {
            var parts: [String] = []
            parts.append(contentsOf: line[..<range.lowerBound]
                .components(separatedBy: " ").filter { !$0.isEmpty })
            parts.append("->")
            parts.append(contentsOf: line[range.upperBound...]
                .components(separatedBy: " ").filter { !$0.isEmpty })
            return parts
        }
        return line.components(separatedBy: " ").filter { !$0.isEmpty }
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
