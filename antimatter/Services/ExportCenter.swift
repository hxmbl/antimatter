import AppKit
import Foundation
import UniformTypeIdentifiers

/// Where `.export` can send the note. Apple Notes and Obsidian are local.
enum ExportDestination: String, CaseIterable {
    case appleNotes = "notes"
    case obsidian
}

/// Local exports of the scratchpad note — no network.
///
/// * **Apple Notes** — the whole note becomes one new note via AppleScript.
/// * **Obsidian** — the note is written as a markdown file into the vault
///   the user picks in a save panel (`…Antimatter.md`), so the pane stays a
///   plain-text markdown file and Obsidian just reads it.
@MainActor
enum ExportCenter {

    /// Performs the export. `text` should be the current scratchpad contents.
    /// Returns a short user-visible outcome for a notice, or throws a
    /// localized error for the caller to surface.
    static func export(_ destination: ExportDestination, text: String) throws -> String {
        switch destination {
        case .appleNotes: return try exportToAppleNotes(text)
        case .obsidian: return try exportToObsidian(text)
        }
    }

    private enum ExportError: LocalizedError {
        case appleScript(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .appleScript(let message): message
            case .cancelled: nil
            }
        }
    }


    private static func exportToAppleNotes(_ text: String) throws -> String {
        // The first line is the note title, the rest the body — mirroring how
        // Notes structures a new note from a title + body.
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = clean.components(separatedBy: .newlines)
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let body = lines.dropFirst().joined(separator: "\n")

        let noteTitle = title.isEmpty ? "Antimatter note" : title
        // Let Notes pick the default account rather than hard-coding "iCloud",
        // which fails for users whose notes live "On My Mac" or another account.
        let script = """
        tell application "Notes"
            make new note with properties {name:\(appleScriptEscape(noteTitle)), body:\(appleScriptEscape(body))}
        end tell
        """
        try runAppleScript(script)
        let shown = noteTitle.count > 40 ? String(noteTitle.prefix(40)) + "…" : noteTitle
        return "Exported to Apple Notes — “\(shown)”"
    }

    private static func appleScriptEscape(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func runAppleScript(_ source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ExportError.appleScript("Couldn't build the AppleScript.")
        }
        script.executeAndReturnError(&error)
        if let error {
            let message = error["NSAppleScriptErrorMessage"] as? String
                ?? "The Apple Notes export failed."
            throw ExportError.appleScript(message)
        }
    }


    private static func exportToObsidian(_ text: String) throws -> String {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Antimatter.md"
        panel.message = "Choose where in your Obsidian vault to save this note (as a markdown file)."
        panel.prompt = "Save to Vault"
        guard panel.runModal() == .OK, let url = panel.url else {
            throw ExportError.cancelled
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "Exported to Obsidian — \(url.lastPathComponent)"
    }
}