import SwiftUI
import AppKit

/// Visual knobs for the floating pane. Each knob reads its value from
/// UserDefaults at render time, so Settings changes apply live without a
/// restart; the baked-in fallback is the first-launch default.
enum PaneStyle {
    // MARK: Display Mode

    enum DisplayMode: String, CaseIterable {
        case dock = "dock"
        case menuBar = "menuBar"
        case dropdown = "dropdown"
    }

    static var displayMode: DisplayMode {
        let raw = UserDefaults.standard.string(forKey: "pane.displayMode") ?? "dock"
        return DisplayMode(rawValue: raw) ?? .dock
    }

    // MARK: Transparency

    /// System blur behind the pane. `false` is a flat tint only (raise `tintOpacity`).
    static var usesBlur: Bool {
        UserDefaults.standard.object(forKey: "pane.usesBlur") as? Bool ?? PaneTheme.current.usesBlur
    }

    /// Blur recipe. More see-through → more solid:
    /// `.fullScreenUI`, `.hudWindow`, `.popover`, `.sidebar`, `.menu`,
    /// `.underWindowBackground`, `.headerView`, `.titlebar`, `.contentBackground`
    static let material: NSVisualEffectView.Material = .fullScreenUI

    /// `.behindWindow` lets the desktop show through. `.withinWindow` blurs only app content.
    static let blending: NSVisualEffectView.BlendingMode = .behindWindow

    /// Extra wash on top of the blur. `0` is blur-only (most transparent).
    /// Neutral-theme presets (default, grid light/dark) keep the original
    /// label-color wash so the pane stays gray-on-gray; only colorful themes
    /// tint with their accent.
    static var tint: Color {
        switch PaneTheme.current.id {
        case "default", "grid-light", "grid-dark":
            return Color(nsColor: .labelColor)
        default:
            return PaneTheme.current.tint
        }
    }
    static var tintOpacity: Double {
        (UserDefaults.standard.object(forKey: "pane.tintOpacity") as? Double) ?? 0.10
    }

    /// Fades the entire window, including text. `1` is no extra fade.
    static var windowAlpha: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "pane.windowAlpha") as? Double) ?? 1.0)
    }

    // MARK: Chrome

    static var cornerRadius: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "pane.cornerRadius") as? Double) ?? PaneTheme.current.cornerRadius)
    }
    static let padding: CGFloat = 16

    /// Height of the quiet status strip under the editor.
    static let footerHeight: CGFloat = 26

    /// Space reserved at the top so text starts below the traffic lights.
    /// The pane itself extends to the window's top edge, so the title bar
    /// area uses the exact same material as the typing surface.
    static let titleBarInset: CGFloat = 12
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
    static let borderWidth: CGFloat = 0.5

    // MARK: Theme

    static var backgroundColor: Color { PaneTheme.current.background }
    static var textColor: Color { PaneTheme.current.text }
    static var accentColor: Color { PaneTheme.current.accent }
    static var textNSColor: NSColor { PaneTheme.current.textNSColor }
    static var accentNSColor: NSColor { PaneTheme.current.accentNSColor }
    /// Syntax markers and code comments stay the system "secondary" gray —
    /// accenting them would tint whole notes and fight the plain-text ethos.
    static var secondaryTextNSColor: NSColor { NSColor.secondaryLabelColor }
    static var gridPaper: Bool { PaneTheme.current.gridPaper }

    // MARK: Type

    /// Runtime-adjustable (Settings); falls back to the theme until set.
    static var fontSize: CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "fontSize") as? Int) ?? PaneTheme.current.fontSize)
    }
    static let lineSpacing: CGFloat = 4

    // MARK: Scroller

    /// Overlay scroller that appears while scrolling and fades out afterward.
    static let showScrollerWhileScrolling = true

    // MARK: Behavior

    /// Identifies the pane: SwiftUI scene id, `openWindow` id, and
    /// NSWindow.identifier all use this so the hot key can find the window.
    static let windowIdentifier = "pane"

    /// UserDefaults key marking the one-time welcome notice as shown.
    static let didWelcomeKey = "did.welcome"

    /// Keeps the pane above ordinary windows.
    static var floatsAboveOtherApps: Bool {
        UserDefaults.standard.object(forKey: "pane.floats") as? Bool ?? true
    }

    /// Escape hides the pane (the hot key brings it back).
    static var hidesOnEscape: Bool {
        UserDefaults.standard.object(forKey: "pane.hidesOnEscape") as? Bool ?? true
    }
    static var showWordCount: Bool {
        UserDefaults.standard.object(forKey: "pane.showWordCount") as? Bool ?? false
    }

    /// UserDefaults key the pane's frame is autosaved under; relaunches
    /// reopen where the user left it.
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