import SwiftUI
import AppKit

/// Applies the floating-pane window settings once the hosting window exists.
struct WindowConfigurator: NSViewRepresentable {
    private static var configuredModes: [ObjectIdentifier: PaneStyle.DisplayMode] = [:]

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        let mode = PaneStyle.displayMode
        let key = ObjectIdentifier(window)
        guard Self.configuredModes[key] != mode else { return }
        Self.configuredModes[key] = mode
        // In menu-bar / dropdown modes the pane lives in MenuBarController's
        // panel, not this SwiftUI window. Skip the window-level chrome (frame
        // autosave in particular) so it doesn't fight the panel, keep the
        // SwiftUI window hidden, and still apply the live styling so the
        // panel honors the appearance settings.
        guard mode == .dock else {
            Self.removeTrafficLights(from: window)
            if !(window is NSPanel) {
                window.orderOut(nil)
            }
            PaneWindowStyler.applyLive(to: window)
            return
        }
        // Dock mode runs as a regular app window: give it a standard,
        // obvious title bar with the traffic-light controls so it reads as
        // a normal macOS window rather than a chrome-less floating pane.
        Self.showStandardTitleBar(on: window)
        // The SwiftUI primary pane gets the canonical identifier; ⌘N windows
        // arrive with their own unique ones, which must be kept so they can
        // be closed and found individually.
        let windowID = window.identifier?.rawValue
        if windowID == nil || !windowID!.hasPrefix(PaneStyle.windowIdentifier) {
            window.identifier = NSUserInterfaceItemIdentifier(PaneStyle.windowIdentifier)
        }
        // Restores the saved frame synchronously; the size and screen clamp
        // below then reins in frames saved before a smaller contentMaxSize
        // existed or on a display that is no longer connected. ⌘N windows
        // already carry their own unique autosave names.
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName(PaneStyle.frameAutosaveName)
            // SwiftUI may leave its own stale restore key behind. It must not
            // override the explicit pane autosave key above.
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame AppWindow")
        }
        window.setFrameAutosaveName(window.frameAutosaveName)
        let windowMaxSize = NSSize(width: PaneStyle.windowMaxWidth, height: PaneStyle.windowMaxHeight)
        let windowMinSize = NSSize(width: PaneStyle.windowMinWidth, height: PaneStyle.windowMinHeight)
        window.maxSize = windowMaxSize
        window.minSize = windowMinSize
        window.contentMaxSize = NSSize(width: PaneStyle.maxWidth, height: PaneStyle.maxHeight)
        Self.restoreValidFrame(for: window, maxSize: windowMaxSize)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = PaneStyle.hasShadow
        window.isMovableByWindowBackground = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
        PaneWindowStyler.applyLive(to: window)
    }

    /// Keeps the user's position when it is still usable. A disconnected
    /// monitor can leave AppKit with an origin that no current screen owns,
    /// so recover to the main screen instead of opening the pane invisibly.
    private static func restoreValidFrame(for window: NSWindow, maxSize: NSSize) {
        var frame = window.frame
        frame.size.width = min(max(frame.width, window.minSize.width), maxSize.width)
        frame.size.height = min(max(frame.height, window.minSize.height), maxSize.height)

        let screens = NSScreen.screens
        let visibleFrames = screens.map(\.visibleFrame)
        let hasUsableIntersection = visibleFrames.contains { visible in
            let intersection = frame.intersection(visible)
            let visibleWidth = min(frame.width, visible.width) * 0.25
            let visibleHeight = min(frame.height, visible.height) * 0.25
            return intersection.width >= visibleWidth && intersection.height >= visibleHeight
        }

        if !hasUsableIntersection {
            let visible = NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame
            if let visible {
                frame.origin = NSPoint(
                    x: visible.midX - frame.width / 2,
                    y: visible.midY - frame.height / 2
                )
            }
        } else if let visible = visibleFrames.max(by: {
            let lhs = frame.intersection($0)
            let rhs = frame.intersection($1)
            return lhs.width * lhs.height < rhs.width * rhs.height
        }) {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }

        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    /// The pane is controlled by the global shortcut, not window controls.
    /// Hide the buttons explicitly because SwiftUI may recreate titlebar
    /// accessories after the window's style is configured.
    private static func removeTrafficLights(from window: NSWindow) {
        window.styleMask.remove([.closable, .miniaturizable])
        for button in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.standardWindowButton(.closeButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    /// Restores the standard macOS title bar and traffic-light controls for
    /// the dock-mode window. Run before the window is shown so the native
    /// bar is laid out normally and the close button works.
    private static func showStandardTitleBar(on window: NSWindow) {
        window.styleMask.insert([.closable, .miniaturizable])
        for button in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            window.standardWindowButton(button)?.isHidden = false
            window.standardWindowButton(button)?.isEnabled = true
        }
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
    }
}

/// Applies the settings that live on the NSWindow itself (rather than in
/// SwiftUI) — level, fade, corner radius, and the content-size clamp.
/// Called at launch for the initial look and again from ContentView whenever
/// a related setting changes, so the pane restyles without a restart.
@MainActor
enum PaneWindowStyler {
    static func applyToPane() {
        switch PaneStyle.displayMode {
        case .dock:
            // Restyle every open pane so a Settings change touches the ⌘N
            // windows too, not just the primary one.
            for window in NSApplication.shared.windows where WindowManager.isPane(window) {
                applyLive(to: window)
            }
        case .menuBar, .dropdown:
            guard let window = MenuBarController.shared.panel else { return }
            applyLive(to: window)
        }
    }

    static func applyLive(to window: NSWindow) {
        window.level = PaneStyle.floatsAboveOtherApps ? .floating : .normal
        window.alphaValue = PaneStyle.windowAlpha
        window.contentView?.layer?.cornerRadius = PaneStyle.effectiveCornerRadius
        window.contentMaxSize = NSSize(width: PaneStyle.maxWidth, height: PaneStyle.maxHeight)
        window.invalidateShadow()
    }
}
