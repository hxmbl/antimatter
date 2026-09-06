import Foundation

/// Turns typed hyphen runs into smart dashes, in the editor, while leaving
/// thematic breaks alone. `--` becomes an en dash (`–`), `---` becomes an em
/// dash (`—`) when it sits inside a line, and `---` on its own line — which
/// Markdown renders as a horizontal rule — stays three raw hyphens.
///
/// Conversion is deferred one keystroke so `---` stays reachable: a `--` run
/// is left raw until the next character lands. If that character is another
/// hyphen the run becomes `---` (em dash, or a raw hr on its own line); if
/// it's anything else the finished `--` collapses to an en dash.
nonisolated enum DashSubstitution {
    /// What `shouldChangeTextIn` should do. `accept` inserts the character as
    /// typed; `rewrite` replaces `range` with `text` and the typed character
    /// is consumed by that replacement:
    ///
    /// - typed non-hyphen: `range` is the trailing hyphen run in the current
    ///   text and `text` is the dash *plus the typed character* (so `--a`
    ///   becomes `–a` in one undoable edit);
    /// - typed hyphen (inline `---`): `range` covers just the hyphens that
    ///   already exist (the typed hyphen is suppressed, not part of the
    ///   replacement), and `text` is the em dash alone.
    enum Outcome: Equatable {
        case accept
        case rewrite(range: NSRange, text: String)
    }

    /// Compute the substitution for inserting a single `typed` character into
    /// `text` immediately before `location` (the caret). Line breaks are
    /// recognised via `newline` so the "own line" test is deterministic.
    static func outcome(
        typing typed: Character,
        into text: String,
        at location: Int,
        newline: Character = "\n"
    ) -> Outcome {
        let ns = text as NSString
        let nsNewline = String(newline)
        let upTo = ns.substring(with: NSRange(location: 0, length: location))
        let trailing = trailingHyphens(in: upTo, nsNewline: nsNewline)

        if typed == "-" {
            let run = trailing + 1
            if run == 2 {
                // `--`: leave raw — it may become `---` next keystroke.
                return .accept
            }
            if run >= 3 {
                if isAtLineStart(upTo, trailingHyphens: trailing, nsNewline: nsNewline) {
                    // On its own line: a horizontal rule. Keep the raw hyphens.
                    return .accept
                }
                // Inline `---` → em dash. Replace only the hyphens that
                // already sit in the buffer; the typed hyphen is never
                // inserted (return false suppresses it).
                return .rewrite(range: NSRange(location: location - trailing, length: trailing), text: "—")
            }
            return .accept
        }

        // A non-hyphen lands. Collapse a finished hyphen run just before it.
        // `>= 3` on its own line is a horizontal rule and must stay raw; every
        // other finished run becomes a dash (`--`→en, `---`∨more inline→em),
        // with the typed character carried along.
        if trailing >= 2, !(trailing >= 3 && isAtLineStart(upTo, trailingHyphens: trailing, nsNewline: nsNewline)) {
            let dash = trailing == 2 ? "–" : "—"
            return .rewrite(range: NSRange(location: location - trailing, length: trailing), text: dash + String(typed))
        }
        return .accept
    }

    /// Number of consecutive `-` at the end of `upTo`.
    private static func trailingHyphens(in upTo: String, nsNewline: String) -> Int {
        var n = 0
        for ch in upTo.unicodeScalars.reversed() {
            if ch == "-" { n += 1 } else { break }
        }
        return n
    }

    /// True when everything before the hyphen run on this line is whitespace
    /// (so the run is the first thing on its line → a thematic break).
    private static func isAtLineStart(_ upTo: String, trailingHyphens: Int, nsNewline: String) -> Bool {
        let beforeRun = upTo.dropLast(trailingHyphens)
        let synthetic = CharacterSet(charactersIn: " \t" + nsNewline)
        return beforeRun.unicodeScalars.allSatisfy { synthetic.contains($0) }
    }
}
