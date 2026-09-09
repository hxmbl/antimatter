import SwiftUI
import AppKit

struct PaneTheme: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var backgroundColor: String
    var textColor: String
    var accentColor: String
    var tintColor: String
    var usesBlur: Bool
    var gridPaper: Bool
    var cornerRadius: Double
    var fontSize: Int

    private var followsSystemAppearance: Bool { id == "default" }

    private var isDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var background: Color {
        if followsSystemAppearance && isDarkAppearance {
            return Color(hex: "#1C1C1E")
        }
        return Color(hex: backgroundColor)
    }

    var text: Color {
        if followsSystemAppearance && isDarkAppearance {
            return Color(hex: "#E5E5E7")
        }
        return Color(hex: textColor)
    }

    var accent: Color { Color(hex: accentColor) }
    var tint: Color { Color(hex: tintColor) }

    var textNSColor: NSColor {
        if followsSystemAppearance && isDarkAppearance {
            return NSColor(hex: "#E5E5E7")
        }
        return NSColor(hex: textColor)
    }

    var accentNSColor: NSColor { NSColor(hex: accentColor) }
    var tintNSColor: NSColor { NSColor(hex: tintColor) }
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: CGFloat
        switch hex.count {
        case 6: (r, g, b) = (CGFloat((int >> 16) & 0xFF) / 255, CGFloat((int >> 8) & 0xFF) / 255, CGFloat(int & 0xFF) / 255)
        default: (r, g, b) = (1, 1, 1)
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6: (r, g, b) = (Double((int >> 16) & 0xFF) / 255, Double((int >> 8) & 0xFF) / 255, Double(int & 0xFF) / 255)
        default: (r, g, b) = (1, 1, 1)
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension PaneTheme {
    static let builtIn: [PaneTheme] = [
        // Light themes
        PaneTheme(id: "default", name: "Antimatter", backgroundColor: "#FFFFFF", textColor: "#1C1C1E", accentColor: "#007AFF", tintColor: "#007AFF", usesBlur: true, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "cream", name: "Cream", backgroundColor: "#FFF8E7", textColor: "#3C3226", accentColor: "#D4A574", tintColor: "#D4A574", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "paper", name: "Paper", backgroundColor: "#F5F0EB", textColor: "#2C2C2E", accentColor: "#E85D3A", tintColor: "#E85D3A", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "mint", name: "Mint", backgroundColor: "#E8F5E9", textColor: "#1B2E1B", accentColor: "#2E7D32", tintColor: "#2E7D32", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "ocean", name: "Ocean", backgroundColor: "#E3F2FD", textColor: "#0D2137", accentColor: "#1565C0", tintColor: "#1565C0", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "lavender", name: "Lavender", backgroundColor: "#F3E5F5", textColor: "#2C1320", accentColor: "#7B1FA2", tintColor: "#7B1FA2", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),

        // Dark themes
        PaneTheme(id: "midnight", name: "Midnight", backgroundColor: "#1C1C1E", textColor: "#E5E5E7", accentColor: "#0A84FF", tintColor: "#0A84FF", usesBlur: true, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "charcoal", name: "Charcoal", backgroundColor: "#2C2C2E", textColor: "#E5E5E7", accentColor: "#FF9F0A", tintColor: "#FF9F0A", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "obsidian", name: "Obsidian", backgroundColor: "#1A1A2E", textColor: "#E0E0E0", accentColor: "#E94560", tintColor: "#E94560", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "forest", name: "Forest", backgroundColor: "#1B2E1B", textColor: "#C8E6C9", accentColor: "#66BB6A", tintColor: "#66BB6A", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "deep-sea", name: "Deep Sea", backgroundColor: "#0D2137", textColor: "#B3D4FC", accentColor: "#42A5F5", tintColor: "#42A5F5", usesBlur: false, gridPaper: false, cornerRadius: 18, fontSize: 15),

        // Grid themes
        PaneTheme(id: "grid-light", name: "Grid Light", backgroundColor: "#FFFFFF", textColor: "#1C1C1E", accentColor: "#007AFF", tintColor: "#007AFF", usesBlur: false, gridPaper: true, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "grid-dark", name: "Grid Dark", backgroundColor: "#1C1C1E", textColor: "#E5E5E7", accentColor: "#0A84FF", tintColor: "#0A84FF", usesBlur: false, gridPaper: true, cornerRadius: 18, fontSize: 15),
        PaneTheme(id: "grid-green", name: "Grid Green", backgroundColor: "#F0F7F0", textColor: "#1C1C1E", accentColor: "#2E7D32", tintColor: "#2E7D32", usesBlur: false, gridPaper: true, cornerRadius: 18, fontSize: 15),
    ]
}

extension PaneTheme {
    private static let themeKey = "pane.themeID"
    private static let customThemeKey = "pane.customTheme"

    static var current: PaneTheme {
        let id = UserDefaults.standard.string(forKey: themeKey) ?? "default"
        if id == "custom",
           let data = UserDefaults.standard.data(forKey: customThemeKey),
           let theme = try? JSONDecoder().decode(PaneTheme.self, from: data) {
            return theme
        }
        return builtIn.first { $0.id == id } ?? builtIn[0]
    }

    static func set(_ theme: PaneTheme) {
        UserDefaults.standard.set(theme.id, forKey: themeKey)
        if theme.id == "custom" {
            if let data = try? JSONEncoder().encode(theme) {
                UserDefaults.standard.set(data, forKey: customThemeKey)
            }
        }
    }
}
