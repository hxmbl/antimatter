import Foundation

// MARK: - Deep link handling

enum DeepLinkRouter {

    /// Commands that external callers (deep links, the loopback bridge) may
    /// execute. Destructive or disruptive commands — delete, clear, quit,
    /// export — are excluded to prevent silent data loss from any local process.
    ///
    /// `.exit` used to be listed here while `.quit` was not, even though the two
    /// are exact synonyms (`IntentExecution.action` treats them identically), so
    /// the stated policy was trivially bypassable: any local process could send
    /// `antimatter://command?line=.exit` and quit the app. Neither is allowed now.
    ///
    /// Matching is on the *whole* command, not a bare prefix: a prefix test let
    /// `.timerx`, `.replaceall` and friends through the same door.
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
            "\(prefix)switch",
        ]
    }()

    /// Returns true when `line` is a dot-command safe for external callers.
    nonisolated static func isSafeCommand(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix(IntentParser.commandPrefix) else {
            // Plain text — safe for note creation / append.
            return true
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Accept the command word, or the word immediately followed by one of
        // its own sub-arguments (`.timer cancel all`, `.timer 25 soup`).
        guard let head = words.first else { return false }
        if safeCommands.contains(head) { return true }
        guard words.count > 1, safeCommands.contains("\(head) \(words[1])") else { return false }
        return true
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
        // Take the *still-encoded* value and decode it here, so the `+` rule is
        // applied before percent-decoding rather than after. Decoding first (via
        // `queryItems`) and then substituting corrupted ordinary text: Raycast
        // encodes spaces as `+`, so `C++` arrives as `C%2B%2B`; `queryItems`
        // correctly decodes that to `C++`, and the blanket substitution then
        // turned it into `C  `.
        //
        // Decoding after the substitution is the standard form order and gets
        // both right: a bare `+` (form-encoded space, e.g. `line=.timer+5`)
        // becomes a space, while `%2B` survives the substitution untouched and
        // percent-decodes to the `+` the user typed.
        guard let raw = components.percentEncodedQueryItems?.first(where: { $0.name == key })?.value
        else { return nil }
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
