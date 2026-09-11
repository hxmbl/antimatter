import SwiftUI

/// Runtime settings on a single page. Everything here applies immediately —
/// the note restyles itself live.
struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("conversion.network") private var currencyNetworkEnabled = false
    @AppStorage("pane.displayMode") private var displayMode = "menuBar"
    @AppStorage("codeBlocks.lineNumbers") private var showLineNumbers = false
    @AppStorage("pane.showWordCount") private var showWordCount = false

    @AppStorage("hotKey.control") private var usesControl = true
    @AppStorage("hotKey.option") private var usesOption = true
    @AppStorage("hotKey.command") private var usesCommand = false
    @AppStorage("hotKey.shift") private var usesShift = false
    @AppStorage("hotKey.keyCode") private var keyCode = 49

    @AppStorage("fontSize") private var fontSize = 15
    @AppStorage("pane.cornerRadius") private var cornerRadius = 18.0
    @AppStorage("pane.maxWidth") private var maxWidth = 600.0
    @AppStorage("pane.usesBlur") private var usesBlur = true
    @AppStorage("pane.tintOpacity") private var tintOpacity = 0.10
    @AppStorage("pane.windowAlpha") private var windowAlpha = 1.0
    @AppStorage("pane.floats") private var floatsAboveOtherApps = true
    @AppStorage("pane.hidesOnEscape") private var hidesOnEscape = true

    @State private var shortcutNotice: String?
    @State private var shortcutNoticeTask: Task<Void, Never>?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var currentShortcut: GlobalShortcut {
        GlobalShortcut(control: usesControl, option: usesOption, command: usesCommand, shift: usesShift, keyCode: keyCode)
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Automatic").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, value in
                    LaunchPreferences.appearanceChanged(value)
                }

                Picker("Show as", selection: $displayMode) {
                    Text("Dock").tag("dock")
                    Text("Menu Bar").tag("menuBar")
                }
                .pickerStyle(.segmented)
                .onChange(of: displayMode) { _, _ in
                    LaunchPreferences.apply()
                }
            } header: {
                Label("General", systemImage: "gearshape")
            } footer: {
                Text("Automatic follows your Mac's look; Light or Dark pins the app to that style. Show as picks where Antimatter lives — the Dock or the menu bar.")
            }

            Section {
                ShortcutField(shortcut: currentShortcut, onRecord: applyShortcut)
                if let shortcutNotice {
                    Label(shortcutNotice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Use default (⌃⌥ Space)") { applyShortcut(.default) }
            } header: {
                Label("Shortcut", systemImage: "keyboard")
            } footer: {
                Text("Press this shortcut anywhere to show or hide your note. Use a combination that includes ⌃, ⌥, or ⌘ — bare keys and Shift alone are blocked so they can't interrupt your typing. Click Record and press the keys you want; Esc cancels.")
            }

            Section {
                SliderRow(title: "Text size", value: Binding(
                    get: { Double(fontSize) },
                    set: { fontSize = Int($0) }
                ), in: 11...26, step: 1) { "\(Int($0)) pt" }
                SliderRow(title: "Rounded corners", value: $cornerRadius, in: 6...32, step: 1) { "\(Int($0)) pt" }
                SliderRow(title: "Window width", value: $maxWidth, in: 360...640, step: 20) { "\(Int($0))" }
            } header: {
                Label("Window", systemImage: "macwindow")
            } footer: {
                Text("How the note is sized and shaped.")
            }

            Section {
                Toggle("Translucent background", isOn: $usesBlur)
                SliderRow(title: "Background tint", value: $tintOpacity, in: 0...0.30, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                SliderRow(title: "Window opacity", value: $windowAlpha, in: 0.65...1.0, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
            } header: {
                Label("Background", systemImage: "drop.halffull")
            } footer: {
                Text("A translucent background blurs whatever is behind the note. Tint adds a soft color to the background. Opacity dims the whole window, text included.")
            }

            Section {
                Toggle("Keep the window on top of other apps", isOn: $floatsAboveOtherApps)
                Toggle("Hide the window when you press Esc", isOn: $hidesOnEscape)
            } header: {
                Label("Behavior", systemImage: "switch.2")
            } footer: {
                Text("Keeps the note within reach, or clears it out of your way.")
            }

            Section {
                Toggle("Live currency & crypto conversion", isOn: $currencyNetworkEnabled)
                    .onChange(of: currencyNetworkEnabled) { _, enabled in
                        if enabled { CurrencyCenter.shared.activate() }
                    }
                Toggle("Show line numbers in code blocks", isOn: $showLineNumbers)
                Toggle("Show word count", isOn: $showWordCount)
            } header: {
                Label("Notes", systemImage: "note.text")
            } footer: {
                Text("Turn lines like `100 USD → EUR` or `1 btc → usd` into instant answers. Line numbers and word count tidy up your notes as you type.")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(PaneTheme.builtIn) { theme in
                        let isSelected = PaneTheme.current.id == theme.id
                        Button(action: {
                            PaneTheme.set(theme)
                            PaneWindowStyler.applyToPane()
                        }) {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.background)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(isSelected ? theme.accent : .clear, lineWidth: 2)
                                    )
                                    .frame(height: 32)
                                    .overlay(
                                        Text("Aa")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(theme.text)
                                    )
                                Text(theme.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Label("Theme", systemImage: "paintpalette")
            } footer: {
                Text("Pick a built-in look for your note. Each theme sets its own background, text color, and accent.")
            }

            Section {
                Toggle("Sync notes across your devices", isOn: Binding(
                    get: { CloudKitSync.shared.isEnabled },
                    set: { _ in CloudKitSync.shared.toggleSync() }
                ))

                if CloudKitSync.shared.isEnabled {
                    if let lastSync = CloudKitSync.shared.lastSyncDate {
                        Text("Last synced \(lastSync, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    switch CloudKitSync.shared.syncStatus {
                    case .idle: Text("Synced").foregroundStyle(.green)
                    case .syncing: Text("Syncing...").foregroundStyle(.orange)
                    case .error(let msg): Text("Error: \(msg)").foregroundStyle(.red)
                    }
                }

                Text("Notes are encrypted on your device before syncing to iCloud. An iCloud account and configured container are required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("iCloud Sync", systemImage: "icloud")
            }

            Section {
                Button("Restore Defaults") { restoreDefaults() }
            } footer: {
                Text("Antimatter \(version)")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { syncToActiveChord() }
    }

    /// Writes the chord, re-registers it with the system, then snaps the
    /// UI back to whatever was actually accepted — refused combinations
    /// never linger in the field.
    private func applyShortcut(_ chord: GlobalShortcut) {
        usesControl = chord.control
        usesOption = chord.option
        usesCommand = chord.command
        usesShift = chord.shift
        keyCode = chord.keyCode
        PaneHotKey.shared.reinstall()
        let active = PaneHotKey.shared.activeChord
        let accepted = GlobalShortcut(control: active.control, option: active.option, command: active.command, shift: active.shift, keyCode: active.keyCode)
        usesControl = accepted.control
        usesOption = accepted.option
        usesCommand = accepted.command
        usesShift = accepted.shift
        keyCode = accepted.keyCode

        if accepted.isWellDefined && accepted == chord {
            shortcutNotice = nil
            shortcutNoticeTask?.cancel()
        } else if !chord.isWellDefined {
            showShortcutNotice("Shortcuts need Control, Option, or Command — bare keys and Shift alone would swallow typing everywhere.")
        } else {
            showShortcutNotice("That shortcut is already in use by another app — the previous shortcut stayed active.")
        }
    }

    private func showShortcutNotice(_ text: String) {
        shortcutNotice = text
        shortcutNoticeTask?.cancel()
        shortcutNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { shortcutNotice = nil }
        }
    }

    private func syncToActiveChord() {
        let active = PaneHotKey.shared.activeChord
        usesControl = active.control
        usesOption = active.option
        usesCommand = active.command
        usesShift = active.shift
        keyCode = active.keyCode
    }

    private func restoreDefaults() {
        appearance = "system"
        LaunchPreferences.appearanceChanged("system")
        displayMode = "menuBar"
        currencyNetworkEnabled = false
        showLineNumbers = false
        showWordCount = false

        fontSize = 15
        cornerRadius = 18
        maxWidth = 600
        usesBlur = true
        tintOpacity = 0.10
        windowAlpha = 1.0
        floatsAboveOtherApps = true
        hidesOnEscape = true
        LaunchPreferences.apply()
    }
}

/// A titled, number-out slider row for the grouped form.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let `in`: ClosedRange<Double>
    let step: Double
    let valueText: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Slider(value: $value, in: `in`, step: step)
            Text(valueText(value))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
    }
}