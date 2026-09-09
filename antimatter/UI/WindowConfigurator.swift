import SwiftUI
import AppKit

/// Applies the floating-pane window settings once the hosting window exists.
struct WindowConfigurator: NSViewRepresentable {
    private static let configuredWindows = NSHashTable<NSWindow>.weakObjects()

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window, Self.configuredWindows.contains(window) { return }
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window, !Self.configuredWindows.contains(window) else { return }
        Self.configuredWindows.add(window)
        window.identifier = NSUserInterfaceItemIdentifier(PaneStyle.windowIdentifier)
        // Restores the saved frame synchronously; the size clamp below then
        // reins in any frame saved before a smaller contentMaxSize existed.
        // Note SwiftUI also keeps its own frame-restore keys in defaults
        // ("NSWindow Frame …AppWindow…"); ours is applied later and wins.
        window.setFrameAutosaveName(PaneStyle.frameAutosaveName)
        let windowMaxSize = NSSize(width: PaneStyle.windowMaxWidth, height: PaneStyle.windowMaxHeight)
        let windowMinSize = NSSize(width: PaneStyle.windowMinWidth, height: PaneStyle.windowMinHeight)
        window.maxSize = windowMaxSize
        window.minSize = windowMinSize
        window.contentMaxSize = NSSize(width: PaneStyle.maxWidth, height: PaneStyle.maxHeight)
        if window.frame.width > windowMaxSize.width || window.frame.height > windowMaxSize.height {
            var frame = window.frame
            frame.size.width = min(frame.width, windowMaxSize.width)
            frame.size.height = min(frame.height, windowMaxSize.height)
            window.setFrame(frame, display: true)
        }
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(PaneStyle.frameAutosaveName)")
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame AppWindow")
        window.setFrameAutosaveName(PaneStyle.frameAutosaveName)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = PaneStyle.hasShadow
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
        PaneWindowStyler.applyLive(to: window)
    }
}

/// Applies the settings that live on the NSWindow itself (rather than in
/// SwiftUI) — level, fade, corner radius, and the content-size clamp.
/// Called at launch for the initial look and again from ContentView whenever
/// a related setting changes, so the pane restyles without a restart.
@MainActor
enum PaneWindowStyler {
    static func applyToPane() {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == PaneStyle.windowIdentifier
        }) else { return }
        applyLive(to: window)
    }

    static func applyLive(to window: NSWindow) {
        window.level = PaneStyle.floatsAboveOtherApps ? .floating : .normal
        window.alphaValue = PaneStyle.windowAlpha
        window.contentView?.layer?.cornerRadius = PaneStyle.cornerRadius
        window.contentMaxSize = NSSize(width: PaneStyle.maxWidth, height: PaneStyle.maxHeight)
        window.invalidateShadow()
    }
}
