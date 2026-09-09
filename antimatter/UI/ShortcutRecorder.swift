import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: four modifier toggles plus one Carbon key code.
/// Same shape `PaneHotKey.Chord` hands to the Carbon event system, kept
/// independent here so the recorder doesn't drag the pixie engine around.
struct GlobalShortcut: Equatable {
    var control = false
    var option = false
    var command = false
    var shift = false
    var keyCode = 49

    static let `default` = GlobalShortcut(control: true, option: true, command: false, shift: false, keyCode: kVK_Space)

    /// A chord with no Control/Option/Command isn't registered — bare keys
    /// and Shift alone would swallow ordinary typing system-wide.
    var isWellDefined: Bool { control || option || command }

    /// "⌃⌥ Space" style rendering.
    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if command { text += "⌘" }
        if shift { text += "⇧" }
        text += Self.keyName(keyCode) ?? "?"
        return text
    }

    static func from(event: NSEvent) -> GlobalShortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return GlobalShortcut(
            control: flags.contains(.control),
            option: flags.contains(.option),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            keyCode: Int(event.keyCode)
        )
    }

    /// Held-modifier prefix shown live while recording; only the four
    /// meaningful modifiers are reflected.
    static func modifierPrefix(for flags: NSEvent.ModifierFlags) -> String {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.command) { s += "⌘" }
        if f.contains(.shift) { s += "⇧" }
        return s
    }

    /// Keys that only change modifier state (⌃ ⌥ ⌘ ⇧, caps, fn). The
    /// recorder waits for a real key on top of these.
    static func isModifierKey(_ code: Int) -> Bool {
        modifierKeyCodes.contains(code)
    }

    private static let modifierKeyCodes: Set<Int> = [
        kVK_CapsLock, kVK_Function,
        kVK_Control, kVK_RightControl,
        kVK_Option, kVK_RightOption,
        kVK_Command, kVK_RightCommand,
        kVK_Shift, kVK_RightShift,
    ]

    /// Carbon key code → human-readable name for the chosen key.
    static func keyName(_ code: Int) -> String? {
        switch code {
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Return: return "Return"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Del Fwd"
        case kVK_Escape: return "Esc"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"

        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"

        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"

        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"

        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"

        default: return nil
        }
    }
}

/// A click-to-record shortcut field. While recording it watches key events
/// with local monitors (which it swallows), shows the held modifiers live,
/// and commits the chord on the next real key. Escape cancels.
struct ShortcutField: View {
    let shortcut: GlobalShortcut
    var onRecord: (GlobalShortcut) -> Void
    var onCancel: (() -> Void) = {}

    @State private var isRecording = false
    @State private var pressingNow = ""
    @State private var keyDownMonitor: Any?
    @State private var flagsMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            field
            Button(isRecording ? "Stop" : "Record") { toggleRecording() }
        }
        .onDisappear { stopMonitoring() }
    }

    private var field: some View {
        Group {
            if isRecording {
                Text(pressingNow.isEmpty ? "Press the new shortcut…" : (pressingNow + " · finish with a key"))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(shortcut.display)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isRecording ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleRecording() }
    }

    private func toggleRecording() {
        if isRecording { cancelRecording() } else { startRecording() }
    }

    private func startRecording() {
        stopMonitoring()
        withAnimation { isRecording = true }
        pressingNow = ""
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { self.handleKeyDown(event) }
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { self.pressingNow = GlobalShortcut.modifierPrefix(for: event.modifierFlags) }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            cancelRecording()
            return
        }
        guard !GlobalShortcut.isModifierKey(code) else { return }
        stopMonitoring()
        withAnimation { isRecording = false }
        pressingNow = ""
        onRecord(GlobalShortcut.from(event: event))
    }

    private func cancelRecording() {
        stopMonitoring()
        withAnimation { isRecording = false }
        pressingNow = ""
        onCancel()
    }

    private func stopMonitoring() {
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyDownMonitor = nil
        flagsMonitor = nil
    }
}