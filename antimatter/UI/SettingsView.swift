import SwiftUI

/// Runtime settings, organized into General / Hot Key / Appearance tabs.
/// Everything here applies immediately — the pane restyles itself live.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotKeySettingsView()
                .tabItem { Label("Hot Key", systemImage: "keyboard") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 560, minHeight: 460)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("conversion.network") private var currencyNetworkEnabled = false
    @AppStorage("pane.displayMode") private var displayMode = "dock"
    @AppStorage("codeBlocks.lineNumbers") private var showLineNumbers = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, value in
                    LaunchPreferences.appearanceChanged(value)
                }
            } header: {
                Label("Theme", systemImage: "sun.max.fill")
            } footer: {
                Text("Follow the current macOS appearance, or pin the one you like. Changes apply to the pane and settings windows immediately.")
            }

            Section {
                Picker("Mode", selection: $displayMode) {
                    Text("Dock").tag("dock")
                    Text("Menu Bar").tag("menuBar")
                    Text("Dropdown").tag("dropdown")
                }
                .pickerStyle(.segmented)
                .onChange(of: displayMode) { _, _ in
                    LaunchPreferences.apply()
                }
            } header: {
                Label("Display Mode", systemImage: "macwindow.on.rectangle")
            } footer: {
                Text("Dock keeps the app in the Dock and Cmd+Tab. Menu Bar puts it in the system menu bar with a dropdown panel. Dropdown shows the panel from the top center of the screen, like Spotlight.")
            }

            Section {
                Toggle("Live currency & crypto conversion", isOn: $currencyNetworkEnabled)
                    .onChange(of: currencyNetworkEnabled) { _, enabled in
                        if enabled { CurrencyCenter.shared.activate() }
                    }
            } header: {
                Label("Conversion", systemImage: "dollarsign.circle")
            } footer: {
                Text("Fetches exchange rates (fiat and crypto) from a third party once an hour and converts lines like `100 USD → EUR` or `1 btc → usd`. Off by default — keep it off for a fully offline note.")
            }

            Section {
                Toggle("Show line numbers in code blocks", isOn: $showLineNumbers)
            } header: {
                Label("Code Blocks", systemImage: "chevron.left.forwardslash.chevron.right")
            } footer: {
                Text("Syntax highlighting supports Swift, Python, JavaScript, TypeScript, Rust, Go, Bash, C, C++, Java, Ruby, HTML, CSS, JSON, YAML, SQL, and Markdown. Strings, comments, and numbers are highlighted by default.")
            }

            Section {
                Toggle("Enable iCloud Sync", isOn: Binding(
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
                Text("Antimatter \(version) — all settings apply immediately.")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
    }

    private func restoreDefaults() {
        appearance = "system"
        LaunchPreferences.appearanceChanged("system")
        currencyNetworkEnabled = false
        displayMode = "dock"
        showLineNumbers = false
        LaunchPreferences.apply()
    }
}

// MARK: - Hot Key

private struct HotKeySettingsView: View {
    @AppStorage("hotKey.control") private var usesControl = true
    @AppStorage("hotKey.option") private var usesOption = true
    @AppStorage("hotKey.command") private var usesCommand = false
    @AppStorage("hotKey.shift") private var usesShift = false
    @AppStorage("hotKey.keyCode") private var keyCode = 49

    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private var currentShortcut: GlobalShortcut {
        GlobalShortcut(control: usesControl, option: usesOption, command: usesCommand, shift: usesShift, keyCode: keyCode)
    }

    var body: some View {
        Form {
            Section {
                ShortcutField(shortcut: currentShortcut, onRecord: apply)
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Restore default (⌃⌥ Space)") { apply(.default) }
            } header: {
                Label("Global Shortcut", systemImage: "keyboard")
            } footer: {
                Text("The shortcut reveals and hides the pane from anywhere, even when antimatter isn't active.\n\nControl, Option, or Command is required — bare keys and Shift-only chords would swallow typing system-wide, so the previous shortcut stays active instead. Click Record and press the keys you want; Esc cancels.")
            }
        }
        .formStyle(.grouped)
        .onAppear { syncToActiveChord() }
    }

    /// Writes the chord, re-registers it with the system, then snaps the
    /// UI back to whatever was actually accepted — refused combinations
    /// never linger in the field.
    private func apply(_ chord: GlobalShortcut) {
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
            notice = nil
            noticeTask?.cancel()
        } else if !chord.isWellDefined {
            showNotice("Shortcuts need Control, Option, or Command — bare keys and Shift alone would swallow typing everywhere.")
        } else {
            showNotice("That shortcut is already in use by another app — the previous shortcut stayed active.")
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
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
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @AppStorage("pane.themeID") private var themeID = "default"
    @AppStorage("fontSize") private var fontSize = 15
    @AppStorage("pane.cornerRadius") private var cornerRadius = 18.0
    @AppStorage("pane.maxWidth") private var maxWidth = 600.0
    @AppStorage("pane.usesBlur") private var usesBlur = true
    @AppStorage("pane.tintOpacity") private var tintOpacity = 0.10
    @AppStorage("pane.windowAlpha") private var windowAlpha = 1.0
    @AppStorage("pane.floats") private var floatsAboveOtherApps = true
    @AppStorage("pane.hidesOnEscape") private var hidesOnEscape = true

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                    ForEach(PaneTheme.builtIn) { theme in
                        Button {
                            PaneTheme.set(theme)
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.background)
                                    .overlay {
                                        if theme.gridPaper {
                                            ThemeSwatchGrid()
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(themeID == theme.id ? theme.accent : Color.clear, lineWidth: 2)
                                    )
                                    .frame(width: 60, height: 40)
                                Text(theme.name)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("\(theme.name) — \(theme.backgroundColor)")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("Theme", systemImage: "paintpalette")
            } footer: {
                Text("Switching themes restyles the pane's colors, material, and grid instantly. Font size, corner radius, and translucency below override the theme until you change theme.")
            }

            Section {
                HStack(spacing: 12) {
                    Text("Aa")
                        .font(.system(size: CGFloat(fontSize), weight: .semibold))
                        .frame(width: 40, height: 38)
                        .foregroundStyle(Color.accentColor)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    Slider(value: Binding(
                        get: { Double(fontSize) },
                        set: { fontSize = Int($0) }
                    ), in: 11...26, step: 1) {
                        Text("Font size")
                    }
                    Text("\(fontSize) pt")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            } header: {
                Label("Type", systemImage: "textformat.size")
            } footer: {
                Text("The pane's base text size. Change it here and the editor adopts it live.")
            }

            Section {
                SliderRow(title: "Corner radius", value: $cornerRadius, in: 6...32, step: 1) { "\(Int($0)) pt" }
                SliderRow(title: "Max width", value: $maxWidth, in: 360...640, step: 20) { "\(Int($0))" }
            } header: {
                Label("Frame", systemImage: "macwindow")
            } footer: {
                Text("Rounding and reach of the floating pane itself.")
            }

            Section {
                Toggle("Translucent background", isOn: $usesBlur)
                SliderRow(title: "Wash", value: $tintOpacity, in: 0...0.30, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                    .disabled(!usesBlur)
                    .opacity(usesBlur ? 1 : 0.4)
                SliderRow(title: "Fade", value: $windowAlpha, in: 0.65...1.0, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
            } header: {
                Label("Material", systemImage: "drop.halffull")
            } footer: {
                Text("Blur lets the desktop show through, tinted by a soft wash. Fade dims the whole window, text included. Turning translucency off makes the desktop tint the only background.")
            }

            Section {
                Toggle("Float above other windows", isOn: $floatsAboveOtherApps)
                Toggle("Hide the pane on Escape", isOn: $hidesOnEscape)
            } header: {
                Label("Behavior", systemImage: "switch.2")
            }

            Section {
                Button("Restore Defaults") { restoreDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    private func restoreDefaults() {
        PaneTheme.set(PaneTheme.builtIn[0])
        fontSize = 15
        cornerRadius = 18
        maxWidth = 600
        usesBlur = true
        tintOpacity = 0.10
        windowAlpha = 1.0
        floatsAboveOtherApps = true
        hidesOnEscape = true
    }
}

/// A tiny grid overlay for theme swatches that use grid paper.
private struct ThemeSwatchGrid: View {
    var body: some View {
        Canvas { context, size in
            let path = Path { path in
                var x: CGFloat = 5
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 5
                }
                var y: CGFloat = 5
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += 5
                }
            }
            context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
        }
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
                .frame(width: 84, alignment: .leading)
            Slider(value: $value, in: `in`, step: step)
            Text(valueText(value))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
    }
}