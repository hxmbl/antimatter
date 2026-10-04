import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private(set) var panel: NSPanel?
    private var keyDownMonitor: Any?
    private var isSetup = false

    func setup() {
        guard !isSetup else { return }
        isSetup = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.toolTip = "Antimatter"
            button.action = #selector(handleStatusButton)
            button.target = self
            // Left click toggles the pane; right click pops the context menu
            // below, so the status bar alone stays fully usable.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func handleStatusButton() {
        guard let event = NSApp.currentEvent else {
            togglePanel()
            return
        }
        if event.type == .rightMouseUp || event.type == .rightMouseDown {
            showStatusMenu()
            return
        }
        togglePanel()
    }

    /// The right-click menu: reveal the pane or quit without the Dock.
    private func showStatusMenu() {
        let menu = NSMenu(title: "Antimatter")

        let open = NSMenuItem(title: "Open Pane", action: #selector(openPane), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Antimatter", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 6, y: button.frame.height + 6), in: button)
        }
    }

    @objc private func openPane() {
        showPanel()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func teardown() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        removeEscapeMonitor()
        isSetup = false
    }

    /// Always leaves at most one live Escape monitor, whichever exit path is
    /// taken.
    private func removeEscapeMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        keyDownMonitor = nil
    }

    @objc func togglePanel() {
        guard let panel = panel else {
            showPanel()
            return
        }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        if panel == nil { createPanel() }
        guard let panel else { return }

        let mode = PaneStyle.displayMode
        let fallbackVisibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame

        if mode == .dropdown {
            if let screenFrame = screenForStatusItem?.visibleFrame ?? fallbackVisibleFrame {
                panel.setFrameOrigin(NSPoint(
                    x: screenFrame.midX - panel.frame.width / 2,
                    y: screenFrame.maxY - panel.frame.height - 8
                ))
            }
        } else if let button = statusItem?.button, let window = button.window {
            let buttonRect = window.convertToScreen(button.frame)
            panel.setFrameOrigin(NSPoint(
                x: buttonRect.midX - panel.frame.width / 2,
                y: buttonRect.minY - panel.frame.height - 4
            ))
        } else if let visible = fallbackVisibleFrame {
            // No status-item window to anchor to (auto-hidden menu bar, or a
            // status item whose window is momentarily unavailable). Without
            // this the panel kept its constructor frame and opened pinned at
            // the screen origin.
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 16,
                y: visible.maxY - panel.frame.height - 8
            ))
        }

        // `.dropdown` is a palette, not a sticky note: it has to get out of the
        // way when the user clicks into another app. Forcing
        // `hidesOnDeactivate = false` left a floating-level 400×500 panel
        // sitting over every other app, swallowing their clicks.
        panel.hidesOnDeactivate = (mode == .dropdown)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private var screenForStatusItem: NSScreen? {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            return NSScreen.main ?? NSScreen.screens.first
        }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let point = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func createPanel() {
        let contentView = ContentView()
            .frame(width: 400, height: 500)

        let hostingView = NSHostingView(rootView: contentView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.nonactivatingPanel, .titled, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hostingView
        panel.identifier = NSUserInterfaceItemIdentifier(PaneStyle.windowIdentifier)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = "Antimatter"

        // A new panel means a new Escape monitor: drop any survivor first so
        // `teardown()`/mode switches can never leave two live.
        removeEscapeMonitor()
        installEscapeMonitor(for: panel)

        self.panel = panel
    }

    /// Escape only reaches this monitor when the note itself is not in a
    /// position to act on it.
    ///
    /// It used to consume Escape unconditionally (and unconditionally hide the
    /// pane), which stole the key from three handlers that run *after* a local
    /// monitor: the completion list's own `case 53: dismiss()`, the reference
    /// view's `q/Esc close`, and `PaneTextView.keyDown`'s
    /// `dismissActiveDotcommands()`. Because it never consulted
    /// `PaneStyle.hidesOnEscape`, the Settings toggle was a no-op in menu-bar
    /// and dropdown modes.
    private func installEscapeMonitor(for panel: NSPanel) {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard let panel,
                  panel.isKeyWindow,
                  event.keyCode == 53   // Escape
            else { return event }

            // A completion list anywhere in the app owns this key. Checked
            // explicitly so the answer does not depend on which order AppKit
            // happens to call local monitors in.
            guard !CommandCompletionPanel.isAnyPanelOpen else { return event }

            guard PaneStyle.hidesOnEscape else { return event }

            guard !(panel.firstResponder is PaneTextView) else {
                // The note's text view is first responder, so
                // `PaneTextView.keyDown` owns Escape from here on: it closes
                // the reference view, cancels timers/stopwatches/reminders and
                // a running paste stream, and only then hides the pane (when
                // `hidesOnEscape` is on). Consuming here would pre-empt all of
                // it.
                return event
            }

            // Nothing inside the pane would ever see this key — a footer
            // button or a chip holds focus — so fall back to hiding.
            panel.orderOut(nil)
            return nil
        }
    }
}