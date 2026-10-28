import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by `SettingsOpener.open()`; handled by `SettingsOpenBridge`.
    static let antimatterOpenSettings = Notification.Name("antimatter.openSettings")
}

/// Opens the SwiftUI `Settings` scene without the deprecated
/// `showSettingsWindow:` selector, and temporarily elevates accessory
/// (menu-bar) apps to `.regular` so the window can become key.
@MainActor
final class SettingsOpener: NSObject {
    static let shared = SettingsOpener()

    /// Window scene id for the always-live `@Environment(\.openSettings)` host.
    /// Must not be a pane id — menu-bar mode orders those out.
    static let bridgeWindowIdentifier = "antimatter.settingsBridge"

    /// True while we flipped `.accessory` → `.regular` solely to show Settings.
    private var elevatedForSettings = false
    /// Set when the hidden bridge window has appeared.
    private(set) var isReady = false

    private override init() {
        super.init()
    }

    /// Menu-item target/action entry point.
    @objc func openSettings(_ sender: Any?) {
        open()
    }

    func markReady() {
        isReady = true
        parkBridgeWindow()
    }

    /// Opens Settings. Returns `false` when the scene bridge isn't up yet.
    @discardableResult
    func open() -> Bool {
        guard isReady else { return false }

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
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .antimatterOpenSettings, object: nil)

            // Settings can take a moment to appear; retry before failing.
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(50))
                if let window = Self.findSettingsWindow() {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    // Float briefly so accessory→regular transitions don't
                    // leave Settings behind the frontmost app.
                    window.level = .floating
                    try? await Task.sleep(for: .milliseconds(100))
                    window.level = .normal
                    return
                }
            }

            // openSettings was a silent no-op — undo the Dock flash.
            restoreAccessoryIfNeeded()
            NoticeCenter.shared.show("Couldn't open Settings.")
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

    /// Keep the bridge alive (don't `orderOut`) but invisible and out of the
    /// window cycle — `openSettings` needs a live scene tree on Tahoe.
    ///
    /// The window must stay at a normal, layout-satisfiable size: resizing a
    /// SwiftUI `Window` host down to 1×1 makes AppKit throw
    /// "marked as needing another Update Constraints in Window pass".
    private static let bridgeSize = NSSize(width: 320, height: 200)
    private func parkBridgeWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == Self.bridgeWindowIdentifier {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.collectionBehavior.insert([.transient, .ignoresCycle, .canJoinAllSpaces])
                window.setFrame(
                    NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: Self.bridgeSize),
                    display: false
                )
            }
        }
    }

    /// SwiftUI's Settings window id (underscores — not dotted).
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    static func findSettingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue == bridgeWindowIdentifier {
                return false
            }
            if window.identifier?.rawValue == settingsWindowIdentifier {
                return true
            }
            // Title match: don't require isVisible — the window may still be
            // ordering in when we first look.
            if window.styleMask.contains(.titled),
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

/// Tiny always-on Window scene that owns `@Environment(\.openSettings)`.
/// Scene order: this Window must be declared before `Settings`.
struct SettingsOpenBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
            .onAppear { SettingsOpener.shared.markReady() }
            .onReceive(NotificationCenter.default.publisher(for: .antimatterOpenSettings)) { _ in
                // Defer one turn: calling openSettings synchronously from a
                // notification can crash toolbar layout on macOS Tahoe.
                Task { @MainActor in
                    openSettings()
                }
            }
    }
}
