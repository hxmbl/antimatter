import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hot key and toggles the pane when it fires.
@MainActor
final class PaneHotKey {
    static let shared = PaneHotKey()

    /// The chord actually registered with the system.
    struct Chord: Equatable {
        var control = false
        var option = false
        var command = false
        var shift = false
        var keyCode = 49
    }

    private(set) var activeChord = Chord()

    var onToggle: (() -> Void)?
    /// Recreates the pane after the user closed it with the red button.
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
            // Hot-key events arrive on the main thread, so no Sendable hop
            // is needed — assume the actor isolation directly.
            let controller = Unmanaged<PaneHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.fireToggle()
            }
            return noErr
        }, 1, &spec, context, &eventHandler)
        guard status == noErr else { return }
        registerChord()
    }

    /// Swaps to whatever chord PaneStyle now reports.
    func reinstall() {
        registerChord()
    }

    private func registerChord() {
        let chord = Chord(
            control: PaneStyle.hotKeyUsesControl,
            option: PaneStyle.hotKeyUsesOption,
            command: PaneStyle.hotKeyUsesCommand,
            shift: PaneStyle.hotKeyUsesShift,
            keyCode: Int(PaneStyle.hotKeyCode)
        )
        // Refuse chords that would swallow ordinary typing system-wide:
        // no modifier at all, or shift alone (shift+space is an input-method
        // staple). The previously registered chord stays live instead, and
        // `activeChord` keeps telling the truth about which one that is.
        guard chord.control || chord.option || chord.command else { return }

        // Carbon owns one hot key per signature/id pair, so the old
        // registration must be released before the new one can take its
        // place. Swap carefully: if the new chord fails to register (likely
        // already bound by another app), the previous one is restored rather
        // than orphaned — before this fix the pane could quietly lose its
        // working hot key (and Settings still showed it as active).
        let previous = activeChord
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let newRef = Self.register(chord) {
            hotKeyRef = newRef
            activeChord = chord
        } else if previous.control || previous.option || previous.command,
                  let restored = Self.register(previous) {
            hotKeyRef = restored
        }
    }

    /// Registers `chord` and returns its reference, or nil if refused.
    private static func register(_ chord: Chord) -> EventHotKeyRef? {
        var modifiers: UInt32 = 0
        if chord.control { modifiers |= UInt32(controlKey) }
        if chord.option { modifiers |= UInt32(optionKey) }
        if chord.command { modifiers |= UInt32(cmdKey) }
        if chord.shift { modifiers |= UInt32(shiftKey) }
        let hotKeyID = EventHotKeyID(signature: OSType(0x50414E45) /* 'PANE' */, id: 1)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(chord.keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return nil }
        return newRef
    }

    private func fireToggle() {
        onToggle?()
    }

    /// Shows the pane when hidden, hides the focused pane when visible.
    func togglePane() {
        let mode = PaneStyle.displayMode
        switch mode {
        case .dock:
            let manager = WindowManager.shared
            let candidate = manager.keyPane ?? manager.frontmostPane
            if let candidate, candidate.isVisible {
                candidate.orderOut(nil)
            } else if candidate != nil {
                revealPane()
            } else {
                openWindow?()
            }
        case .menuBar, .dropdown:
            MenuBarController.shared.togglePanel()
        }
    }

    /// Brings the frontmost pane forward; creates one when none exist.
    func revealPane() {
        let mode = PaneStyle.displayMode
        switch mode {
        case .dock:
            NSApplication.shared.activate()
            let manager = WindowManager.shared
            if let window = manager.keyPane ?? manager.frontmostPane {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow?()
            }
        case .menuBar, .dropdown:
            MenuBarController.shared.showPanel()
        }
    }
}
