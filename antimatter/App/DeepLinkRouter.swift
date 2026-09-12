import Foundation

// MARK: - Deep link handling

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
            break
        }
    }

    // MARK: URL parsing

    private static func value(_ key: String, from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let raw = components.queryItems?.first(where: { $0.name == key })?.value else { return nil }
        // `queryItems` decodes `%2B` but not the form-encoded `+` for spaces;
        // browsers and blunt clients send `line=.timer+5`.
        return raw.replacingOccurrences(of: "+", with: " ")
    }
}
