import Foundation

// MARK: - Usage statistics

/// Persistent usage counters behind `.stats`: characters typed, characters
/// deleted, and the moment Antimatter was first run.
@MainActor
final class StatsCenter {
    static let shared = StatsCenter()

    private struct Payload: Codable {
        var typed: Int
        var deleted: Int
        var installDate: Date
        var commandUsage: [String: Int]

        private enum CodingKeys: String, CodingKey {
            case typed, deleted, installDate, commandUsage
        }

        init(typed: Int, deleted: Int, installDate: Date, commandUsage: [String: Int] = [:]) {
            self.typed = typed
            self.deleted = deleted
            self.installDate = installDate
            self.commandUsage = commandUsage
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            typed = try values.decode(Int.self, forKey: .typed)
            deleted = try values.decode(Int.self, forKey: .deleted)
            installDate = try values.decode(Date.self, forKey: .installDate)
            commandUsage = try values.decodeIfPresent([String: Int].self, forKey: .commandUsage) ?? [:]
        }
    }

    private var payload: Payload
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL = StatsCenter.defaultFileURL()) {
        self.fileURL = fileURL
        if let data = Persistence.readData(from: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload(typed: 0, deleted: 0, installDate: Date())
            flush()
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        StorageLocation.directory(named: "stats").appendingPathComponent("stats.json")
    }

    /// Characters the user has typed in the pane.
    var typed: Int { payload.typed }

    /// Characters the user has removed from the pane.
    var deleted: Int { payload.deleted }

    /// The first moment Antimatter recorded a launch.
    var installDate: Date { payload.installDate }

    private var commandUsage: [String: Int] {
        get { payload.commandUsage }
        set { payload.commandUsage = newValue }
    }

    /// Accumulate one edit's inserted and removed character counts.
    func record(typed: Int, deleted: Int) {
        guard typed > 0 || deleted > 0 else { return }
        payload.typed += typed
        payload.deleted += deleted
        scheduleSave()
    }

    /// Record a successfully accepted completion for usage-based ranking.
    func record(command: String) {
        commandUsage[command, default: 0] += 1
        scheduleSave()
    }

    func usageCount(for command: String) -> Int {
        commandUsage[command, default: 0]
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        _ = Persistence.writeData(data, to: fileURL)
    }

    // MARK: .stats report

    /// The reference block `.stats` expands into.
    var report: String {
        let notes = NoteStore.shared.notes.count
        let voided = NoteStore.shared.trash.count
        var out: [String] = []
        out.append("Antimatter — usage")
        out.append("")
        out.append("  typed         \(grouped(typed)) characters")
        out.append("  deleted       \(grouped(deleted)) characters")
        out.append("  notes         \(notes)\(voided > 0 ? " · \(voided) resting in The Void" : "")")
        out.append("  version       \(versionText)")
        out.append("  using since   \(sinceText)")
        out.append("")
        out.append("Every character above landed in a note — or never quite did.")
        return out.joined(separator: "\n")
    }

    // MARK: Formatting

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        default: return "1.0"
        }
    }

    private var sinceText: String {
        "\(sinceDateText) · \(Self.durationText(since: installDate, to: Date()))"
    }

    private var sinceDateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: installDate)
    }

    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "13 months", "2 weeks", "3 days" — how long the user has been using
    /// Antimatter, in the largest natural unit.
    nonisolated static func durationText(since date: Date, to now: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date, to: now)
        if let years = components.year, years >= 1 { return plural(years, "year") }
        if let months = components.month, months >= 1 { return plural(months, "month") }
        if let days = components.day, days >= 7 { return plural(days / 7, "week") }
        if let days = components.day, days >= 1 { return plural(days, "day") }
        if let hours = components.hour, hours >= 1 { return plural(hours, "hour") }
        if let minutes = components.minute, minutes >= 1 { return plural(minutes, "minute") }
        return "a few moments"
    }

    nonisolated private static func plural(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
