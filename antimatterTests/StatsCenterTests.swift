import Foundation
import Testing
@testable import antimatter

/// Tests for the usage counters behind `.stats`.
@MainActor
struct StatsCenterTests {

    private func freshCenter() -> StatsCenter {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-stats-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("stats.json")
        return StatsCenter(fileURL: url)
    }

    @Test func freshCenterStartsEmpty() {
        let center = freshCenter()
        #expect(center.typed == 0)
        #expect(center.deleted == 0)
        #expect(abs(center.installDate.timeIntervalSinceNow) < 60)
    }

    @Test func recordingAccumulates() {
        let center = freshCenter()
        center.record(typed: 12, deleted: 0)
        center.record(typed: 0, deleted: 3)
        center.record(typed: 45, deleted: 2)
        #expect(center.typed == 57)
        #expect(center.deleted == 5)
    }

    @Test func zeroEditsAreIgnored() {
        let center = freshCenter()
        center.record(typed: 0, deleted: 0)
        center.flush()
        #expect(center.typed == 0)
        #expect(center.deleted == 0)
    }

    @Test func valuesPersistAcrossReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-stats-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("stats.json")
        let center = StatsCenter(fileURL: url)
        center.record(typed: 100, deleted: 40)
        center.record(command: ".sum")
        center.record(command: ".sum")
        center.flush()

        let reloaded = StatsCenter(fileURL: url)
        #expect(reloaded.typed == 100)
        #expect(reloaded.deleted == 40)
        #expect(reloaded.usageCount(for: ".sum") == 2)
    }

    @Test func reloadKeepsTheOriginalInstallDate() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-stats-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("stats.json")
        let center = StatsCenter(fileURL: url)
        #expect(abs(center.installDate.timeIntervalSinceNow) < 60)
        center.flush()

        let reloaded = StatsCenter(fileURL: url)
        #expect(reloaded.installDate == center.installDate)
    }

    @Test func reportCoversTheRequestedFields() {
        let center = freshCenter()
        center.record(typed: 1_234, deleted: 56)
        let report = center.report
        #expect(report.contains("Antimatter"))
        #expect(report.contains("1,234"))
        #expect(report.contains("56"))
        #expect(report.contains("notes"))
        #expect(report.contains("version"))
        #expect(report.contains("using since"))
    }

    @Test func durationTextReadsNaturally() {
        let now = Date()
        let calendar = Calendar.current
        let minutesAgo = now.addingTimeInterval(-2 * 60)
        let daysAgo = now.addingTimeInterval(-3 * 24 * 3600)
        let weeksAgo = now.addingTimeInterval(-9 * 24 * 3600)
        let monthsAgo = calendar.date(byAdding: .month, value: -2, to: now)!
        let yearsAgo = calendar.date(byAdding: .year, value: -1, to: now)!

        func duration(_ from: Date) -> String {
            StatsCenter.durationText(since: from, to: now)
        }

        #expect(duration(minutesAgo).contains("minute"))
        #expect(duration(daysAgo).contains("day"))
        #expect(duration(weeksAgo).contains("week"))
        #expect(duration(monthsAgo).contains("month"))
        #expect(duration(yearsAgo).contains("year"))
        #expect(duration(now).contains("moments"))
    }

    @Test func durationPluralizes() {
        let now = Date()
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 3600)
        let oneDayAgo = now.addingTimeInterval(-24 * 3600)
        #expect(StatsCenter.durationText(since: threeDaysAgo, to: now).contains("3 days"))
        #expect(StatsCenter.durationText(since: oneDayAgo, to: now).contains("1 day"))
    }
}