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
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        keyDownMonitor = nil
        isSetup = false
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

        if mode == .dropdown {
            if let screen = screenForStatusItem {
                let screenFrame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: screenFrame.midX - panel.frame.width / 2,
                    y: screenFrame.maxY - panel.frame.height - 8
                ))
            }
        } else {
            if let button = statusItem?.button, let window = button.window {
                let buttonRect = window.convertToScreen(button.frame)
                panel.setFrameOrigin(NSPoint(
                    x: buttonRect.midX - panel.frame.width / 2,
                    y: buttonRect.minY - panel.frame.height - 4
                ))
            }
        }

        panel.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private var screenForStatusItem: NSScreen? {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            return NSScreen.main
        }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let point = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
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

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard let panel, panel.isKeyWindow, event.keyCode == 53 else { return event }
            if PasteStream.shared.isStreaming { return event }
            panel.orderOut(nil)
            return nil
        }

        self.panel = panel
    }
}