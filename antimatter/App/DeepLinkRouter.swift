import Foundation

/// Routes `antimatter://` deep links into the app. The URL scheme is
/// registered in Info.plist; macOS delivers every open to
/// `AppDelegate.application(_:open:)`, which funnels them here.
///
/// Supported forms:
///   antimatter://                         — reveal the pane
///   antimatter://note?text=hello          — create a note with text
///   antimatter://append?text=more         — append to the active note
///   antimatter://command?line=.timer 5    — run a dot-command line
enum DeepLinkRouter {
    @MainActor
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "antimatter" else { return }

        switch url.host?.lowercased() {
        case "note":
            _ = ActionRunner.create(text: value("text", from: url) ?? "")

        case "append":
            _ = ActionRunner.append(text: value("text", from: url) ?? "")

        case "command":
            guard let line = value("line", from: url) else { return }
            _ = ActionRunner.run(line)

        default:
            // Bare `antimatter://` and unknown hosts just bring the pane up.
            break
        }
    }

    private static func value(_ key: String, from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let raw = components.queryItems?.first { $0.name == key }?.value else { return nil }
        // `queryItems` decodes `%2B` but not the form-encoded `+` for spaces;
        // browsers and blunt clients send `line=.timer+5`.
        return raw.replacingOccurrences(of: "+", with: " ")
    }
}