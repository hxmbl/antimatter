import Foundation

// MARK: - Deep link handling

enum DeepLinkRouter {

    /// Commands that external callers (deep links, the loopback bridge) may
    /// execute. Destructive or disruptive commands — delete, clear, quit,
    /// export — are excluded to prevent silent data loss from any local process.
    private nonisolated static let safeCommands: Set<String> = {
        let prefix = IntentParser.commandPrefix
        return [
            "\(prefix)timer", "\(prefix)pomodoro", "\(prefix)stopwatch",
            "\(prefix)stopwatch cancel", "\(prefix)remind",
            "\(prefix)reminder cancel", "\(prefix)cancel",
            "\(prefix)new", "\(prefix)help", "\(prefix)stats",
            "\(prefix)time", "\(prefix)date",
            "\(prefix)sum", "\(prefix)avg", "\(prefix)count",
            "\(prefix)math", "\(prefix)currency",
            "\(prefix)debug", "\(prefix)settings",
            "\(prefix)find", "\(prefix)replace",
            "\(prefix)exit", "\(prefix)switch",
        ]
    }()

    /// Returns true when `line` is a dot-command safe for external callers.
    nonisolated static func isSafeCommand(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix(IntentParser.commandPrefix) else {
            // Plain text — safe for note creation / append.
            return true
        }
        return safeCommands.contains { trimmed.hasPrefix($0) }
    }

    @MainActor
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "antimatter" else { return }

        switch url.host?.lowercased() {
        case "note":
            let text = value("text", from: url) ?? ""
            guard isSafeCommand(text) else { return }
            _ = ActionRunner.create(text: text)

        case "append":
            let text = value("text", from: url) ?? ""
            guard isSafeCommand(text) else { return }
            _ = ActionRunner.append(text: text)

        case "command":
            guard let line = value("line", from: url) else { return }
            guard isSafeCommand(line) else { return }
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
