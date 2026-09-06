import SwiftUI
import UserNotifications

@main
struct AntimatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Antimatter", id: PaneStyle.windowIdentifier) {
            ContentView()
                .containerBackground(.clear, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reveal Scratchpad in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ScratchStore.defaultFileURL()])
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(after: .textEditing) {
                Button("Command Palette…") { PaneIntentSupport.perform(.showCommandPalette) }
                    .keyboardShortcut("p", modifiers: [.command])
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

/// Bridges SwiftUI menu items to NSTextView's text-finder actions; the
/// pane's text view runs the system find bar.
@MainActor
enum FindSupport {
    static func perform(_ action: NSTextFinder.Action) {
        guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else { return }
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        textView.performTextFinderAction(item)
    }
}

/// A menu-level intent for the pane's text view.
@MainActor
enum PaneIntent {
    case showCommandPalette
}

/// Bridges menu items to the pane's coordinator. Both the find bar and the
/// palette live in the text view's delegate — the pane's key window,
/// wherever the caret happened to be, is the entry point.
@MainActor
enum PaneIntentSupport {
    static func perform(_ intent: PaneIntent) {
        guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
              let coordinator = textView.delegate as? PaneEditor.Coordinator
        else { return }
        switch intent {
        case .showCommandPalette:
            coordinator.showCommandPalette(in: textView)
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
        // Load cached rates and, if the opt-in switch is on, refresh them.
        CurrencyCenter.shared.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Lives here, not in the pane's view: the window (and its SwiftUI
        // observers) may not exist when the app quits.
        ScratchStore.shared.flush()
    }

    /// Context-menu bridge for menu-bar (accessory) mode: with no menu bar
    /// there is no Settings item and no ⌘Q, so the pane's right-click menu
    /// is the way out.
    @objc func openSettings(_ sender: Any?) {
        NSApplication.shared.activate()
        // Decide by result, not by responds(): the modern selector may be
        // handled deeper in the responder chain than NSApp itself.
        let modern = Selector(("showSettingsWindow:"))
        if !NSApplication.shared.sendAction(modern, to: nil, from: nil) {
            NSApplication.shared.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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

/// Appearance policy chosen in Settings, applied at launch. The app always
/// stays in the Dock for now; menu-bar (accessory) mode is a later feature.
@MainActor
enum LaunchPreferences {
    static func apply() {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        NSApp.setActivationPolicy(.regular)
    }

    static func appearanceChanged(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
