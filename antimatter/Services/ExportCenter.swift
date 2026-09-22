import AppKit
import Foundation
import UniformTypeIdentifiers

/// Where `.export` can send the note. Apple Notes and Obsidian are local.
/// `json` and `csv` serialize the note text plus the variable table, so a
/// scratchpad of live `:name = expression` values can leave the app.
enum ExportDestination: String, CaseIterable {
    case appleNotes = "notes"
    case obsidian
    case json
    case csv
}

/// Local exports of the scratchpad note — no network.
///
/// * **Apple Notes** — the whole note becomes one new note via AppleScript.
/// * **Obsidian** — the note is written as a markdown file into the vault
///   the user picks in a save panel (`…Antimatter.md`), so the pane stays a
///   plain-text markdown file and Obsidian just reads it.
/// * **JSON** — note text plus every variable with its typed value.
/// * **CSV** — a `name,value,type` table of the variables.
@MainActor
enum ExportCenter {

    /// Performs the export. `text` should be the current scratchpad contents.
    /// Returns a short user-visible outcome for a notice, or throws a
    /// localized error for the caller to surface.
    static func export(_ destination: ExportDestination, text: String) throws -> String {
        switch destination {
        case .appleNotes: return try exportToAppleNotes(text)
        case .obsidian: return try exportToObsidian(text)
        case .json: return try exportToJSON(text)
        case .csv: return try exportToCSV(text)
        }
    }

    private enum ExportError: LocalizedError {
        case appleScript(String)
        case serialize(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .appleScript(let message): message
            case .serialize(let message): message
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


    // MARK: JSON & CSV

    /// The JSON payload: the note text and every variable with its typed
    /// value (`1.5`, `true`, `"hi"`, `[1, 2, 3]`), so an exported scratchpad
    /// can be machine-read elsewhere.
    private static func exportToJSON(_ text: String) throws -> String {
        let table = VariableTable.scan(text)
        var variables: [String: Any] = [:]
        for (name, value) in table {
            guard let converted = jsonValue(value) else { continue }
            variables[name] = converted
        }
        let payload: [String: Any] = ["text": text, "variables": variables]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw ExportError.serialize("Couldn't build the JSON.")
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Antimatter.json"
        panel.message = "Save the note and its variable values as JSON."
        panel.prompt = "Save JSON"
        guard panel.runModal() == .OK, let url = panel.url else {
            throw ExportError.cancelled
        }
        try data.write(to: url)
        return "Exported to JSON — \(url.lastPathComponent)"
    }

    /// A `name,value,type` table of the note's variables. Non-finite and
    /// otherwise unserializable values are skipped.
    private static func exportToCSV(_ text: String) throws -> String {
        let table = VariableTable.scan(text)
        guard !table.isEmpty else {
            return "Nothing to export — define a :name = expression first"
        }
        var rows = ["name,value,type"]
        for name in table.keys.sorted() {
            guard let value = table[name] else { continue }
            rows.append("\(csvEscape(name)),\(csvEscape(IntentParser.format(value))),\(typeName(of: value))")
        }
        let data = rows.joined(separator: "\n").data(using: .utf8) ?? Data()

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Antimatter.csv"
        panel.message = "Save this note's variables as a CSV table."
        panel.prompt = "Save CSV"
        guard panel.runModal() == .OK, let url = panel.url else {
            throw ExportError.cancelled
        }
        try data.write(to: url)
        return "Exported to CSV — \(url.lastPathComponent)"
    }

    /// A JSON-serializable representation of a value, or nil when the value
    /// can't survive serialization (e.g. a non-finite number).
    private static func jsonValue(_ value: SparkValue) -> Any? {
        switch value {
        case .number(let number):
            return number.isFinite ? number : nil
        case .boolean(let boolean):
            return boolean
        case .string(let string):
            return string
        case .list(let items):
            var serialized: [Any] = []
            for item in items {
                guard let converted = jsonValue(item) else { return nil }
                serialized.append(converted)
            }
            return serialized
        }
    }

    private static func typeName(of value: SparkValue) -> String {
        switch value {
        case .number: "number"
        case .boolean: "boolean"
        case .string: "string"
        case .list: "list"
        }
    }

    /// Quotes a CSV cell when it contains a comma, quote, or newline,
    /// doubling any embedded quotes per RFC 4180.
    private static func csvEscape(_ cell: String) -> String {
        guard cell.contains(",") || cell.contains("\"") || cell.contains("\n") else { return cell }
        return "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}