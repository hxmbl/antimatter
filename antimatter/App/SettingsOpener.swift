import AppKit
import SwiftUI

/// Opens the SwiftUI `Settings` scene without the deprecated
/// `showSettingsWindow:` selector, and temporarily elevates accessory
/// (menu-bar) apps to `.regular` so the window can become key.
@MainActor
final class SettingsOpener {
    static let shared = SettingsOpener()

    private var openSettings: (() -> Void)?
    /// True while we flipped `.accessory` → `.regular` solely to show Settings.
    private var elevatedForSettings = false

    private init() {}

    /// Captures `@Environment(\.openSettings)` from a Window-scene view.
    /// Only the App `Window` should call this — not menu-bar / ⌘N
    /// `NSHostingView` trees, whose environment action is a no-op.
    func install(_ action: @escaping () -> Void) {
        openSettings = action
    }

    /// Opens Settings. Returns `false` when no scene bridge has installed yet.
    @discardableResult
    func open() -> Bool {
        guard let openSettings else { return false }

        let needsElevation = PaneStyle.displayMode == .menuBar
            && NSApp.activationPolicy() == .accessory
        if needsElevation {
            NSApp.setActivationPolicy(.regular)
            elevatedForSettings = true
        }

        Task { @MainActor in
            // Give AppKit a beat to apply the new activation policy before
            // asking SwiftUI to materialise the Settings window.
            if needsElevation {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApp.activate(ignoringOtherApps: true)
            openSettings()

            try? await Task.sleep(for: .milliseconds(200))
            if let window = Self.findSettingsWindow() {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else {
                // openSettings was a silent no-op — undo the Dock flash.
                restoreAccessoryIfNeeded()
                NoticeCenter.shared.show("Couldn't open Settings.")
            }
        }
        return true
    }

    /// Called from `SettingsView.onDisappear` when the window closes.
    func settingsDidClose() {
        restoreAccessoryIfNeeded()
    }

    /// `LaunchPreferences.apply()` already set the right policy; drop our
    /// elevation flag so a later Settings close doesn't fight the user.
    func noteActivationPolicyApplied() {
        elevatedForSettings = false
    }

    private func restoreAccessoryIfNeeded() {
        guard elevatedForSettings else { return }
        elevatedForSettings = false
        guard PaneStyle.displayMode == .menuBar else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// SwiftUI tags the Settings window with this identifier.
    private static let settingsWindowIdentifier = "com.apple.SwiftUI.Settings"

    static func findSettingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue == settingsWindowIdentifier {
                return true
            }
            if window.isVisible,
               window.styleMask.contains(.titled),
               window.title.localizedCaseInsensitiveContains("settings")
                || window.title.localizedCaseInsensitiveContains("preferences") {
                return true
            }
            if let contentVC = window.contentViewController,
               String(describing: type(of: contentVC)).contains("Settings") {
                return true
            }
            return false
        }
    }
}

/// Lives on the App `Window` scene so `@Environment(\.openSettings)` resolves
/// against a real Settings scene (scene order: Window before Settings).
struct SettingsOpenBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { SettingsOpener.shared.install { openSettings() } }
    }
}
