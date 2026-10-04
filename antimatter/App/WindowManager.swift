import AppKit
import SwiftUI

// MARK: - Pane window management

/// Extra pane windows get unique identifiers for individual close/restyle.
/// Reads live from NSApplication.shared.windows so all paths stay in sync.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    /// How many frame-autosave slots extra windows cycle through. Bounded so
    /// the app's defaults can't grow one rect entry per window ever opened.
    static let maxWindowSlots = 8

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
    /// menu-bar/dropdown panel is an `NSPanel` and must never answer for one.
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

    /// Opens an independent scratchpad window. Only in Dock mode, where panes are regular titled windows.
    func createNewWindow() {
        guard PaneStyle.displayMode == .dock else {
            NoticeCenter.shared.show("⌘N opens extra windows in Dock display mode")
            return
        }

        let slot = Self.freeSlot()
        let store = NoteStore(fileURL: Self.newStoreURL(), syncEnabled: false)
        extraStores.append(WeakStore(store))
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
            "\(PaneStyle.windowIdentifier).\(slot)"
        )
        // A stable per-slot autosave name is what makes the saved frame
        // readable: with a UUID in the name AppKit wrote a fresh rect entry for
        // every window and could never read one back.
        window.setFrameAutosaveName(Self.frameAutosaveName(for: slot))
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
        guard PaneStyle.displayMode == .dock else { return }
        // Only close real dock windows. `keyPane` falls back to
        // `frontmostPane`, which can answer with the menu-bar/dropdown `NSPanel`
        // — closing that would silently dismiss the accessory panel instead of
        // the note window the user can actually see.
        if let window = frontmostDockPane {
            window.close()
        }
    }

    // MARK: Frame autosave slots

    /// The first slot no live pane window is using. Slots recycle once
    /// `maxWindowSlots` windows are open, so the set of saved frames stays
    /// bounded instead of growing once per ⌘N press forever.
    static func freeSlot() -> Int {
        let used = Set(
            NSApplication.shared.windows
                .filter { isPane($0) }
                .compactMap { window in
                    window.identifier?.rawValue
                        .split(separator: ".").last
                        .flatMap { Int($0) }
                }
        )
        return (0..<maxWindowSlots).first { !used.contains($0) } ?? 0
    }

    static func frameAutosaveName(for slot: Int) -> String {
        "\(PaneStyle.frameAutosaveName).\(slot)"
    }

    // MARK: Per-window stores

    /// Stores owned by the ⌘N windows currently alive, so termination can flush
    /// them. A window's store is otherwise reachable only through its
    /// `ContentView`, and a window being deallocated at quit is never *closed* —
    /// so `willCloseNotification` never fires for it and its last debounced
    /// keystrokes were being dropped on the floor.
    private var extraStores: [WeakStore] = []

    private final class WeakStore {
        weak var store: NoteStore?
        init(_ store: NoteStore) { self.store = store }
    }

    var liveStores: [NoteStore] {
        extraStores.compactMap(\.store)
    }

    /// Each extra window gets its own notes file.
    private static func newStoreURL() -> URL {
        StorageLocation.directory(named: "notes")
            .appendingPathComponent("window-\(UUID().uuidString).json")
    }
}
