import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hot key — control+option+space by default — and
/// toggles the pane whenever it fires, even when the app is inactive.
/// The chord is editable at runtime (Settings); `reinstall` swaps the
/// registration without touching the event handler.
/// All AppKit window work happens on the main actor; the Carbon callback
/// hops over with `Task { @MainActor }`.
@MainActor
final class PaneHotKey {
    static let shared = PaneHotKey()

    var onToggle: (() -> Void)?
    /// Set from SwiftUI's `openWindow` environment action; recreates the
    /// pane after the user closed it with the red button.
    var openWindow: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {}

    func install() {
        guard eventHandler == nil else {
            registerChord()
            return
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<PaneHotKey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in controller.fireToggle() }
            return noErr
        }, 1, &spec, context, &eventHandler)
        guard status == noErr else { return }
        registerChord()
    }

    /// Swaps to whatever chord `PaneStyle` now reports. A chord without any
    /// modifier is refused — registering bare letters system-wide would
    /// swallow ordinary typing everywhere.
    func reinstall() {
        guard PaneStyle.hotKeyUsesControl || PaneStyle.hotKeyUsesOption
                || PaneStyle.hotKeyUsesCommand || PaneStyle.hotKeyUsesShift
        else { return }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registerChord()
    }

    private func registerChord() {
        var modifiers: UInt32 = 0
        if PaneStyle.hotKeyUsesControl { modifiers |= UInt32(controlKey) }
        if PaneStyle.hotKeyUsesOption { modifiers |= UInt32(optionKey) }
        if PaneStyle.hotKeyUsesCommand { modifiers |= UInt32(cmdKey) }
        if PaneStyle.hotKeyUsesShift { modifiers |= UInt32(shiftKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x50414E45) /* 'PANE' */, id: 1)
        RegisterEventHotKey(PaneStyle.hotKeyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func fireToggle() {
        onToggle?()
    }

    /// Shows the pane when hidden or closed, hides it when visible.
    func togglePane() {
        if let window = Self.paneWindow {
            if window.isVisible {
                window.orderOut(nil)
                return
            }
            revealPane()
        } else {
            openWindow?()
        }
    }

    /// Brings the pane forward (hot key when hidden, notification clicks).
    func revealPane() {
        NSApplication.shared.activate()
        if let window = Self.paneWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
    }

    private static var paneWindow: NSWindow? {
        NSApplication.shared.windows.first {
            $0.identifier?.rawValue == PaneStyle.windowIdentifier
        }
    }
}
