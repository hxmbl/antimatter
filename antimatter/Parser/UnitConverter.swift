import Foundation

nonisolated enum UnitConverter {
    private static let linearUnits: [String: (dimension: String, factor: Double)] = [
        // length, base metre
        "mm": ("length", 0.001), "cm": ("length", 0.01), "m": ("length", 1),
        "km": ("length", 1_000), "in": ("length", 0.0254), "ft": ("length", 0.3048),
        "yd": ("length", 0.9144), "mi": ("length", 1_609.344),
        // mass, base kilogram
        "mg": ("mass", 0.000_001), "g": ("mass", 0.001), "kg": ("mass", 1),
        "oz": ("mass", 0.028_349_523_125), "lb": ("mass", 0.453_592_37),
    ]

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
        return CurrencyCenter.convert(value: value, from: fromUnit, to: toUnit)
    }

    private static func isPhysical(_ unit: String) -> Bool {
        linearUnits[unit] != nil
    }


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
         // or be surrounded by spaces, so split around the first arrow.
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
        return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
