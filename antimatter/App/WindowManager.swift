import AppKit
import SwiftUI

/// Extra pane windows get unique identifiers for individual close/restyle.
/// Reads live from NSApplication.shared.windows so all paths stay in sync.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private init() {}

    static func isPane(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true
    }

    var panes: [NSWindow] {
        NSApplication.shared.windows.filter { Self.isPane($0) }
    }

    var frontmostPane: NSWindow? {
        panes.last
    }

    var keyPane: NSWindow? {
        if let key = NSApplication.shared.keyWindow, Self.isPane(key) {
            return key
        }
        return frontmostPane
    }

    /// Opens an independent scratchpad window. Only in Dock mode, where panes are regular titled windows.
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
        window.isReleasedWhenClosed = true
        window.identifier = NSUserInterfaceItemIdentifier(
            "\(PaneStyle.windowIdentifier).\(UUID().uuidString)"
        )
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

    func closeKeyWindow() {
        guard PaneStyle.displayMode == .dock, let window = keyPane else { return }
        window.close()
    }

    /// Each extra window gets its own notes file.
    private static func newStoreURL() -> URL {
        StorageLocation.directory(named: "notes")
            .appendingPathComponent("window-\(UUID().uuidString).json")
    }
}