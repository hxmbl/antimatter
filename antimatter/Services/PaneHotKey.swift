import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hot key — control+option+space by default — and
/// toggles the pane whenever it fires, even when the app is inactive.
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
        guard eventHandler == nil else { return }
        var modifiers: UInt32 = 0
        if PaneStyle.hotKeyUsesControl { modifiers |= UInt32(controlKey) }
        if PaneStyle.hotKeyUsesOption { modifiers |= UInt32(optionKey) }
        if PaneStyle.hotKeyUsesCommand { modifiers |= UInt32(cmdKey) }
        if PaneStyle.hotKeyUsesShift { modifiers |= UInt32(shiftKey) }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<PaneHotKey>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in controller.fireToggle() }
            return noErr
        }, 1, &spec, context, &eventHandler)
        guard status == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x50414E45) /* 'PANE' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func fireToggle() {
        onToggle?()
    }

    /// Shows the pane when hidden or closed, hides it when visible.
    func togglePane() {
        if let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == PaneStyle.windowIdentifier
        }) {
            if window.isVisible {
                window.orderOut(nil)
                return
            }
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
    }
}
