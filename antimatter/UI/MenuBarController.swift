import AppKit
import SwiftUI

@MainActor
final class MenuBarController {
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
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Antimatter")
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }
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
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: screenFrame.midX - panel.frame.width / 2,
                    y: screenFrame.maxY - panel.frame.height
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

        panel.orderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    private func createPanel() {
        let contentView = ContentView()
            .frame(width: 400, height: 500)

        let hostingView = NSHostingView(rootView: contentView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hostingView
        panel.identifier = NSUserInterfaceItemIdentifier(PaneStyle.windowIdentifier)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        // Dismiss on Escape while the panel is key.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard let panel, panel.isKeyWindow, event.keyCode == 53 else { return event }
            panel.orderOut(nil)
            return nil
        }

        self.panel = panel
    }
}