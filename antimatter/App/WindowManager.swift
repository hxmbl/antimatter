import AppKit
import SwiftUI

// MARK: - Pane window management

/// The app has exactly one pane window; this helper finds it among
/// `NSApplication.shared.windows`, which is creation-ordered, includes
/// windows that are ordered out, and mixes the menu-bar `NSPanel` with dock
/// windows — so every lookup below exists to answer "the window the user is
/// actually looking at".
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private init() {}

    // MARK: Window lookup

    static func isPane(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true
    }

    /// Every pane window, in *creation* order. `NSApp.windows` is not
    /// z-ordered and includes windows that are ordered out, so this is a set,
    /// never an ordering — use `frontmostPane` for "the one in front".
    var panes: [NSWindow] {
        NSApplication.shared.windows.filter { Self.isPane($0) }
    }

    /// The pane the user is looking at: the key window when it is a pane,
    /// else the main window, else the frontmost onscreen pane.
    /// `NSApp.windows` cannot answer this — it is creation-ordered, not
    /// z-ordered, and keeps windows that are ordered out — so the global hot
    /// key used to hide a random window, ⌘W could close a hidden one, and
    /// every app switch force-raised whichever was created last.
    var frontmostPane: NSWindow? {
        let app = NSApplication.shared
        if let key = app.keyWindow, Self.isPane(key) { return key }
        if let main = app.mainWindow, Self.isPane(main) { return main }
        return app.orderedWindows.first { Self.isPane($0) && $0.isVisible }
    }

    /// `frontmostPane` restricted to real dock windows (the ⌘N ones). The
    /// menu-bar panel is an `NSPanel` and must never answer for one.
    var frontmostDockPane: NSWindow? {
        let app = NSApplication.shared
        if let key = app.keyWindow, Self.isPane(key), !(key is NSPanel) { return key }
        if let main = app.mainWindow, Self.isPane(main), !(main is NSPanel) { return main }
        return app.orderedWindows.first {
            Self.isPane($0) && $0.isVisible && !($0 is NSPanel)
        }
    }

    var keyPane: NSWindow? {
        if let key = NSApplication.shared.keyWindow, Self.isPane(key) {
            return key
        }
        return frontmostPane
    }

    // MARK: Window lifecycle

    func closeKeyWindow() {
        guard PaneStyle.displayMode == .dock else { return }
        // Only close real dock windows. `keyPane` falls back to
        // `frontmostPane`, which can answer with the menu-bar `NSPanel`
        // — closing that would silently dismiss the accessory panel instead of
        // the note window the user can actually see.
        if let window = frontmostDockPane {
            window.close()
        }
    }
}
