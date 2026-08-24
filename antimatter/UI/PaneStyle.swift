import SwiftUI
import AppKit

/// Visual knobs for the floating pane. Edit this file to restyle the app.
enum PaneStyle {
    // MARK: Transparency

    /// System blur behind the pane. `false` is a flat tint only (raise `tintOpacity`).
    static let usesBlur = true

    /// Blur recipe. More see-through → more solid:
    /// `.fullScreenUI`, `.hudWindow`, `.popover`, `.sidebar`, `.menu`,
    /// `.underWindowBackground`, `.headerView`, `.titlebar`, `.contentBackground`
    static let material: NSVisualEffectView.Material = .fullScreenUI

    /// `.behindWindow` lets the desktop show through. `.withinWindow` blurs only app content.
    static let blending: NSVisualEffectView.BlendingMode = .behindWindow

    /// Extra wash on top of the blur. `0` is blur-only (most transparent).
    static let tint: Color = .black
    static let tintOpacity: Double = 0.10

    /// Fades the entire window, including text. `1` is no extra fade.
    static let windowAlpha: CGFloat = 1.0

    // MARK: Chrome

    static let cornerRadius: CGFloat = 18
    static let padding: CGFloat = 16

    /// Space reserved at the top so text starts below the traffic lights.
    /// The pane itself extends to the window's top edge, so the title bar
    /// area uses the exact same material as the typing surface.
    static let titleBarInset: CGFloat = 30
    static let maxWidth: CGFloat = 600
    static let maxHeight: CGFloat = 900
    static let hasShadow = true

    static let border: Color = .white
    static let borderOpacity: Double = 0.16
    static let borderWidth: CGFloat = 0.5

    // MARK: Type

    static let fontSize: CGFloat = 15
    static let lineSpacing: CGFloat = 4

    // MARK: Scroller

    /// Overlay scroller that appears while scrolling and fades out afterward.
    static let showScrollerWhileScrolling = true

    // MARK: Behavior

    /// Identifies the pane: SwiftUI scene id, `openWindow` id, and
    /// NSWindow.identifier all use this so the hot key can find the window.
    static let windowIdentifier = "pane"

    /// Keeps the pane above ordinary windows.
    static let floatsAboveOtherApps = true

    /// Escape hides the pane (the hot key brings it back).
    static let hidesOnEscape = true

    /// UserDefaults key the pane's frame is autosaved under; relaunches
    /// reopen where the user left it.
    static let frameAutosaveName = "pane-frame"

    // Global hot key: control + option + space. Raw Carbon constants live in
    // `PaneHotKey`; flip these to change the chord.
    static let hotKeyUsesControl = true
    static let hotKeyUsesOption = true
    static let hotKeyUsesCommand = false
    static let hotKeyUsesShift = false
}
