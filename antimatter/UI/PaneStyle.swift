import SwiftUI
import AppKit

enum PaneStyle {

    enum DisplayMode: String, CaseIterable {
        case dock = "dock"
        case menuBar = "menuBar"
        case dropdown = "dropdown"
    }

    static var displayMode: DisplayMode {
        let raw = UserDefaults.standard.string(forKey: "pane.displayMode") ?? "menuBar"
        return DisplayMode(rawValue: raw) ?? .menuBar
    }


    static var usesBlur: Bool {
        UserDefaults.standard.object(forKey: "pane.usesBlur") as? Bool ?? PaneTheme.current.usesBlur
    }

    static let material: NSVisualEffectView.Material = .fullScreenUI

    static let blending: NSVisualEffectView.BlendingMode = .behindWindow

    static var tint: Color {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch PaneTheme.current.id {
        case "default", "grid-light", "grid-dark":
            return isDark ? Color(white: 0) : Color(nsColor: .labelColor)
        default:
            return PaneTheme.current.tint
        }
    }
    static var tintOpacity: Double {
        (UserDefaults.standard.object(forKey: "pane.tintOpacity") as? Double) ?? 0.10
    }

    static var windowAlpha: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "pane.windowAlpha") as? Double) ?? 1.0)
    }


    static var cornerRadius: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "pane.cornerRadius") as? Double) ?? PaneTheme.current.cornerRadius)
    }

    static var cornerRadiusOverride: CGFloat?

    static var effectiveCornerRadius: CGFloat {
        guard displayMode != .dock else { return 0 }
        return cornerRadiusOverride ?? cornerRadius
    }

    static let relaxedCornerRadius: CGFloat = 6

    static let topClipRelaxBand: CGFloat = 24

    static func cornerRadius(forLevel level: CGFloat) -> CGFloat {
        let t = min(max(level, 0), 1)
        return cornerRadius - (cornerRadius - relaxedCornerRadius) * t
    }

    static let padding: CGFloat = 16

    static let footerHeight: CGFloat = 26

    static let titleBarInset: CGFloat = 8
    static var maxWidth: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "pane.maxWidth") as? Double) ?? 600)
    }
    static let maxHeight: CGFloat = 900
    static let windowMaxWidth: CGFloat = 650
    static let windowMaxHeight: CGFloat = 950
    static let windowMinWidth: CGFloat = 300
    static let windowMinHeight: CGFloat = 200
    static let windowDragLip: CGFloat = 6
    static let hasShadow = true

    static let border: Color = .white
    static let borderOpacity: Double = 0.16


    static var backgroundColor: Color { PaneTheme.current.background }
    static var textColor: Color { PaneTheme.current.text }
    static var accentColor: Color { PaneTheme.current.accent }
    static var textNSColor: NSColor { PaneTheme.current.textNSColor }
    static var accentNSColor: NSColor { PaneTheme.current.accentNSColor }
    static var secondaryTextNSColor: NSColor { NSColor.secondaryLabelColor }
    static var gridPaper: Bool { PaneTheme.current.gridPaper }


    static var fontSize: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "fontSize") as? Int) ?? PaneTheme.current.fontSize)
    }
    static let lineSpacing: CGFloat = 4


    static let showScrollerWhileScrolling = true


    static let windowIdentifier = "pane"

    static let didWelcomeKey = "did.welcome"

    /// Keeps the pane above ordinary windows.
    static var floatsAboveOtherApps: Bool {
        UserDefaults.standard.object(forKey: "pane.floats") as? Bool ?? true
    }

    static var hidesOnEscape: Bool {
        UserDefaults.standard.object(forKey: "pane.hidesOnEscape") as? Bool ?? true
    }
    static var showWordCount: Bool {
        UserDefaults.standard.object(forKey: "pane.showWordCount") as? Bool ?? false
    }

    static let frameAutosaveName = "pane-frame"

    // Global hot key: control + option + space by default, editable at
    // runtime in Settings. Raw Carbon key codes live in `PaneHotKey`.
    static var hotKeyUsesControl: Bool {
        UserDefaults.standard.object(forKey: "hotKey.control") as? Bool ?? true
    }
    static var hotKeyUsesOption: Bool {
        UserDefaults.standard.object(forKey: "hotKey.option") as? Bool ?? true
    }
    static var hotKeyUsesCommand: Bool {
        UserDefaults.standard.object(forKey: "hotKey.command") as? Bool ?? false
    }
    static var hotKeyUsesShift: Bool {
        UserDefaults.standard.object(forKey: "hotKey.shift") as? Bool ?? false
    }
    /// Carbon virtual key code; 49 is Space.
    static var hotKeyCode: UInt32 {
        UInt32(UserDefaults.standard.object(forKey: "hotKey.keyCode") as? Int ?? 49)
    }
}