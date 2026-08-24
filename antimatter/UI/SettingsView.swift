import SwiftUI
import Carbon.HIToolbox

/// Runtime settings: hot key chord, font size, appearance, and the
/// menu-bar (Dock-icon-off) mode. Replaces "edit `PaneStyle.swift`".
struct SettingsView: View {
    @AppStorage("fontSize") private var fontSize = 15
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("hotKey.control") private var usesControl = true
    @AppStorage("hotKey.option") private var usesOption = true
    @AppStorage("hotKey.command") private var usesCommand = false
    @AppStorage("hotKey.shift") private var usesShift = false
    @AppStorage("hotKey.keyCode") private var keyCode = 49

    var body: some View {
        Form {
            Section("Hot Key") {
                HStack {
                    Toggle("⌃ Control", isOn: $usesControl)
                    Toggle("⌥ Option", isOn: $usesOption)
                    Toggle("⌘ Command", isOn: $usesCommand)
                    Toggle("⇧ Shift", isOn: $usesShift)
                }
                Picker("Key", selection: $keyCode) {
                    ForEach(Self.keys, id: \.code) { key in
                        Text(key.name).tag(key.code)
                    }
                }
                .onChange(of: usesControl) { _, _ in PaneHotKey.shared.reinstall() }
                .onChange(of: usesOption) { _, _ in PaneHotKey.shared.reinstall() }
                .onChange(of: usesCommand) { _, _ in PaneHotKey.shared.reinstall() }
                .onChange(of: usesShift) { _, _ in PaneHotKey.shared.reinstall() }
                .onChange(of: keyCode) { _, _ in PaneHotKey.shared.reinstall() }
            }
            Section("Text") {
                Slider(value: Binding(
                    get: { Double(fontSize) },
                    set: { fontSize = Int($0) }
                ), in: 11...26, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Text("11")
                } maximumValueLabel: {
                    Text("26")
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, value in LaunchPreferences.appearanceChanged(value) }
                Toggle("Hide Dock icon (menu-bar mode)", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, hidden in LaunchPreferences.dockIconHiddenChanged(hidden) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private static let keys: [(name: String, code: Int)] = [
        ("Space", kVK_Space), ("Tab", kVK_Tab), ("Return", kVK_Return),
        (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("-", kVK_ANSI_Minus),
        ("=", kVK_ANSI_Equal),
        ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D),
        ("E", kVK_ANSI_E), ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H),
        ("I", kVK_ANSI_I), ("J", kVK_ANSI_J), ("K", kVK_ANSI_K), ("L", kVK_ANSI_L),
        ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O), ("P", kVK_ANSI_P),
        ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
        ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X),
        ("Y", kVK_ANSI_Y), ("Z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
        ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
    ]
}
