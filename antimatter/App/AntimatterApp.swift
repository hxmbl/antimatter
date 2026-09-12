import SwiftUI
import AppKit
import UserNotifications

@main
struct AntimatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Antimatter", id: PaneStyle.windowIdentifier) {
            ContentView()
                .containerBackground(.clear, for: .window)
                .onReceive(NotificationCenter.default.publisher(for:  NSApplication.didBecomeActiveNotification)) { _ in
                    if PaneStyle.displayMode == .dock {
                        PaneHotKey.shared.revealPane()
                    }
                }
        }
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Window") { WindowManager.shared.createNewWindow() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Close Window") { WindowManager.shared.closeKeyWindow() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Reveal Notes in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        StorageLocation.directory(named: "notes").appendingPathComponent("notes.json")
                    ])
                }
                .keyboardShortcut("r", modifiers: [.command])
                ForEach(0..<9, id: \.self) { index in
                    Button("Slot \(index + 1)") {
                        _ = NoteStore.shared.note(forSlot: index)
                        PaneHotKey.shared.revealPane()
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { FindSupport.perform(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("Find Next") { FindSupport.perform(.nextMatch) }
                    .keyboardShortcut("g", modifiers: [.command])
                Button("Find Previous") { FindSupport.perform(.previousMatch) }
                    .keyboardShortcut("G", modifiers: [.shift, .command])
            }
        }
        Settings {
            SettingsView()
        }
    }
}

/// Bridges SwiftUI menu items to NSTextView's text-finder actions.
@MainActor
enum FindSupport {
    static func perform(_ action: NSTextFinder.Action) {
        guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else { return }
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        textView.performTextFinderAction(item)
    }
}

/// Timer notifications: clicking one reopens the pane and clears the chip.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            defer { completionHandler() }
            // Only act on clicks for reminders/timers that still exist — a
            // foreign notification with a UUID identifier must not yank the
            // pane forward or dismiss an innocent chip.
            guard let id = UUID(uuidString: identifier) else { return }
            if TimerCenter.shared.timers.contains(where: { $0.id == id }) {
                TimerCenter.shared.dismiss(id)
                PaneHotKey.shared.revealPane()
                return
            }
            if ReminderCenter.shared.reminders.contains(where: { $0.id == id }) {
                ReminderCenter.shared.dismiss(id)
                PaneHotKey.shared.revealPane()
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Banner only — the Glass chime on fire is the one audible signal.
        completionHandler([.banner])
    }
}

/// Appearance and display-mode policy chosen in Settings.
@MainActor
enum LaunchPreferences {
    static func apply() {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }

        let mode = PaneStyle.displayMode
        switch mode {
        case .dock:
            NSApp.setActivationPolicy(.regular)
            MenuBarController.shared.teardown()
            // Switching back to Dock leaves the SwiftUI pane window ordered
            // out from a previous accessory-mode session; bring it forward.
            PaneHotKey.shared.revealPane()
        case .menuBar, .dropdown:
            NSApp.setActivationPolicy(.accessory)
            MenuBarController.shared.setup()
            // The SwiftUI pane window would otherwise float in addition to the
            // panel; keep the app's windows out of the way in accessory modes.
            for window in NSApplication.shared.windows where WindowManager.isPane(window) {
                window.orderOut(nil)
            }
        }
    }

    static func appearanceChanged(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationRouter = NotificationRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        PaneHotKey.shared.onToggle = { PaneHotKey.shared.togglePane() }
        PaneHotKey.shared.install()
        UNUserNotificationCenter.current().delegate = notificationRouter
        LaunchPreferences.apply()
        CurrencyCenter.shared.activate()
        LocalBridge.shared.start()
        Task { @MainActor in
            await CloudKitSync.shared.pull()
        }
    }

    // Without this, AppKit silently terminates a few seconds after the last
    // visible window goes away (e.g. Escape hides the pane in accessory mode).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteStore.shared.flush()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DeepLinkRouter.handle(url) }
        PaneHotKey.shared.revealPane()
    }

    @objc func openSettings(_ sender: Any?) {
        NSApplication.shared.activate()
        let modern = Selector(("showSettingsWindow:"))
        if !NSApplication.shared.sendAction(modern, to: nil, from: nil) {
            NSApplication.shared.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
