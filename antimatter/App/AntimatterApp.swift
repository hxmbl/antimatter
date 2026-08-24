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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationRouter = NotificationRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        PaneHotKey.shared.onToggle = { PaneHotKey.shared.togglePane() }
        PaneHotKey.shared.install()
        UNUserNotificationCenter.current().delegate = notificationRouter
        LaunchPreferences.apply()
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
            if let id = UUID(uuidString: identifier) {
                TimerCenter.shared.dismiss(id)
            }
            PaneHotKey.shared.revealPane()
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Appearance and Dock-icon policy chosen in Settings, applied at launch.
@MainActor
enum LaunchPreferences {
    static func apply() {
        switch UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        if UserDefaults.standard.bool(forKey: "hideDockIcon") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func appearanceChanged(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static func dockIconHiddenChanged(_ hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
    }
}
