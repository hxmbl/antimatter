import AppKit
import SwiftUI

/// Owns the extra pane windows opened with ⌘N. The first pane (SwiftUI scene)
/// keeps a fixed identifier; extras get unique ones so they can be closed and
/// restyled individually. Every query reads live from
/// `NSApplication.shared.windows` instead of holding strong references, so
/// windows dismissed by any path — red button, ⌘W, Escape, display-mode
/// switch — stay in sync automatically.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private init() {}

    /// True for any window that is one of the app's panes.
    static func isPane(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true
    }

    /// All pane windows, back-to-front ordering as reported by AppKit.
    var panes: [NSWindow] {
        NSApplication.shared.windows.filter { Self.isPane($0) }
    }

    /// The frontmost pane window, whether visible or hidden.
    var frontmostPane: NSWindow? {
        panes.last
    }

    /// The pane window currently holding focus, falling back to the frontmost.
    var keyPane: NSWindow? {
        if let key = NSApplication.shared.keyWindow, Self.isPane(key) {
            return key
        }
        return frontmostPane
    }

    /// ⌘N. Opens a fresh, independent scratchpad window. Only meaningful in
    /// Dock mode, where panes are regular titled windows; the menu-bar panel
    /// is a single accessory window by design, so the other modes say so.
    func createNewWindow() {
        guard PaneStyle.displayMode == .dock else {
            NoticeCenter.shared.show("⌘N opens extra windows in Dock display mode")
            return
        }

        let store = NoteStore(fileURL: Self.newStoreURL(), syncEnabled: false)
        let hostingView = NSHostingView(rootView: ContentView(noteStore: store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentView = hostingView
        window.title = "Antimatter"
        // Release on close so ⌘W and the red button fully retire the window
        // from AppKit's list; the SwiftUI primary pane is unaffected because
        // its scene owns it.
        window.isReleasedWhenClosed = true
        window.identifier = NSUserInterfaceItemIdentifier(
            "\(PaneStyle.windowIdentifier).\(UUID().uuidString)"
        )
        // A per-window frame autosave name keeps windows from fighting over
        // the primary pane's saved frame.
        window.setFrameAutosaveName("\(PaneStyle.frameAutosaveName).\(UUID().uuidString)")
        window.tabbingMode = .disallowed

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.center()
        let cascade = 24 * panes.count
        window.setFrameOrigin(NSPoint(
            x: window.frame.origin.x + CGFloat(cascade),
            y: window.frame.origin.y - CGFloat(cascade)
        ))
        window.makeKeyAndOrderFront(nil)
    }

    /// ⌘W. Closes the pane window that has focus; other windows are untouched.
    func closeKeyWindow() {
        guard PaneStyle.displayMode == .dock, let window = keyPane else { return }
        window.close()
    }

    /// Each extra window edits its own notes file so multiple scratchpads can
    /// be open at once without clobbering one another (or the main store).
    private static func newStoreURL() -> URL {
        StorageLocation.directory(named: "notes")
            .appendingPathComponent("window-\(UUID().uuidString).json")
    }
}