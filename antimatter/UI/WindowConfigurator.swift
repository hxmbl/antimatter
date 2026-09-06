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
        if PaneStyle.floatsAboveOtherApps {
            window.level = .floating
        }
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = PaneStyle.windowAlpha
        window.hasShadow = PaneStyle.hasShadow
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = PaneStyle.cornerRadius
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
        window.invalidateShadow()
    }
}
