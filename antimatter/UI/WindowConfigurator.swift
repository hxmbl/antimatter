import SwiftUI
import AppKit

/// Applies the floating-pane window settings once the hosting window exists.
struct WindowConfigurator: NSViewRepresentable {

    /// What `configure` has already done to a live window, keyed by window.
    ///
    /// The key alone was not enough: `ObjectIdentifier` values are recycled
    /// after a window is deallocated, so a brand-new window could inherit a
    /// dead window's "already configured" mark and skip configuration
    /// entirely — never getting its identifier, size limits or frame clamp.
    /// Each entry therefore also holds the window *weakly*, and `prune()` drops
    /// the dead ones on every pass, so the table cannot grow without bound
    /// and a recycled identifier always misses.
    private struct Applied {
        weak var window: NSWindow?
        var mode: PaneStyle.DisplayMode
    }

    private static var applied: [ObjectIdentifier: Applied] = [:]

    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachProbe()
        // A closure that captures nothing: the probe is owned by SwiftUI and
        // holding on to the representable (or its window) here would be a
        // cycle.
        view.onAttach = { WindowConfigurator.configure($0) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // `view.window` is live by now (the view is already in the hierarchy),
        // so this pass is synchronous — the old `DispatchQueue.main.async`
        // deferred configuration by a whole runloop turn, which showed as an
        // unstyled flash every time a window appeared.
        Self.configure(view.window)
    }

    /// Applies the current display mode's settings to `window`, at most once
    /// per (window, mode). Exposed for tests and for the attach probe.
    static func configure(_ window: NSWindow?) {
        guard let window else { return }
        pruneDeadEntries()
        let mode = PaneStyle.displayMode
        let key = ObjectIdentifier(window)
        if let existing = applied[key],
           existing.window === window,
           existing.mode == mode {
            return
        }
        applied[key] = Applied(window: window, mode: mode)
        apply(mode: mode, to: window)
    }

    /// Number of entries whose window has been deallocated. Always 0 outside
    /// of a window-less test.
    static var deadEntryCount: Int {
        applied.values.filter { $0.window == nil }.count
    }

    /// Drops memo entries for windows that no longer exist. Safe to call at
    /// any time; entries for live windows are kept.
    static func pruneDeadEntries() {
        guard applied.contains(where: { $0.value.window == nil }) else { return }
        applied = applied.filter { $0.value.window != nil }
    }

    private static func apply(mode: PaneStyle.DisplayMode, to window: NSWindow) {
        guard mode == .dock else {
            removeTrafficLights(from: window)
            if !(window is NSPanel) {
                window.orderOut(nil)
            }
            PaneWindowStyler.applyLive(to: window)
            return
        }
        showStandardTitleBar(on: window)
        let windowID = window.identifier?.rawValue
        if windowID == nil || !windowID!.hasPrefix(PaneStyle.windowIdentifier) {
            window.identifier = NSUserInterfaceItemIdentifier(PaneStyle.windowIdentifier)
        }
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName(PaneStyle.frameAutosaveName)
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame AppWindow")
        }
        window.setFrameAutosaveName(window.frameAutosaveName)
        let windowMaxSize = NSSize(width: PaneStyle.windowMaxWidth, height: PaneStyle.windowMaxHeight)
        let windowMinSize = NSSize(width: PaneStyle.windowMinWidth, height: PaneStyle.windowMinHeight)
        window.maxSize = windowMaxSize
        window.minSize = windowMinSize
        window.contentMaxSize = NSSize(width: PaneStyle.maxWidth, height: PaneStyle.maxHeight)
        restoreValidFrame(for: window, maxSize: windowMaxSize)
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

/// Fires as soon as AppKit puts the representable's view inside a window.
///
/// `makeNSView` cannot do this work itself: the view it returns is not in a
/// window yet, so `view.window` is nil and anything scheduled from there
/// (`DispatchQueue.main.async { configure(view.window) }`) was a guaranteed
/// no-op — configuration landed a runloop late and showed as an unstyled
/// flash.
private final class WindowAttachProbe: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onAttach?(window)
    }
}

/// Applies the settings that live on the NSWindow itself (level, fade,
/// corner radius, content-size clamp). Called at launch and on settings change.
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