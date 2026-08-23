import Foundation
import Testing
@testable import antimatter

@MainActor
struct ScratchStoreTests {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("scratchpad.md")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    @Test func missingFileLoadsAsEmpty() {
        let store = ScratchStore(fileURL: tempURL())
        #expect(store.text == "")
    }

    @Test func textRoundTripsThroughDisk() {
        let url = tempURL()
        let source = "# scratch\n- [x] milk\n384 * 27"
        let writer = ScratchStore(fileURL: url)
        writer.text = source
        writer.flush()
        #expect(ScratchStore(fileURL: url).text == source)
    }

    @Test func flushWritesImmediatelyEvenWithPendingDebounce() throws {
        let url = tempURL()
        let store = ScratchStore(fileURL: url)
        store.text = "typed just now"
        store.textDidChange()   // schedules a debounced write…
        store.flush()           // …but closing/quit must not wait for it
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "typed just now")
    }
}

@MainActor
struct TimerCenterPruneTests {

    @Test func longFinishedTimersArePrunedOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-timers-\(UUID().uuidString).json")
        let clock = Date(timeIntervalSince1970: 1_000_000)
        // Fired two hours ago and never dismissed: too old to keep around.
        let stale = ActiveTimer(
            id: UUID(), label: "stale", duration: 10,
            endDate: clock.addingTimeInterval(-7_200), createdAt: clock.addingTimeInterval(-7_210),
            firedAt: clock.addingTimeInterval(-7_200)
        )
        try JSONEncoder().encode([stale]).write(to: url)

        let reloaded = TimerCenter(fileURL: url, now: { clock })
        #expect(reloaded.timers.isEmpty)
    }
}

@MainActor
struct TimerCenterTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-timers-\(UUID().uuidString).json")
    }

    @Test func startSchedulesAndDeduplicatesRapidRetries() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let center = TimerCenter(fileURL: tempFile(), now: { clock })

        #expect(center.start(duration: 300, label: "laundry"))
        #expect(center.timers.count == 1)

        clock = clock.addingTimeInterval(1)   // return pressed again a second later
        #expect(!center.start(duration: 300, label: "laundry"))
        #expect(center.timers.count == 1)

        clock = clock.addingTimeInterval(3)   // a genuinely new timer
        #expect(center.start(duration: 300, label: "laundry"))
        #expect(center.timers.count == 2)

        #expect(center.timers[0].endDate == clock.addingTimeInterval(300))
    }

    @Test func invalidDurationsAreRejected() {
        let center = TimerCenter(fileURL: tempFile(), now: Date.init)
        #expect(!center.start(duration: 0, label: ""))
        #expect(!center.start(duration: -5, label: ""))
        #expect(!center.start(duration: IntentParser.maxDuration + 1, label: ""))
    }

    @Test func dismissRemovesAndPersists() {
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let url = tempFile()
        let center = TimerCenter(fileURL: url, now: { clock })
        center.start(duration: 60, label: "tea")
        let id = center.timers[0].id

        center.dismiss(id)
        #expect(center.timers.isEmpty)

        let reloaded = TimerCenter(fileURL: url, now: { clock })
        #expect(reloaded.timers.isEmpty)
    }

    @Test func timersSurviveRelaunchAndExpiredOnesWakeUpDone() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-timers-\(UUID().uuidString).json")

        let first = TimerCenter(fileURL: url, now: { clock })
        first.start(duration: 60, label: "tea")
        first.start(duration: 3_600, label: "dough")

        clock = clock.addingTimeInterval(120)   // the app was closed for two minutes
        let second = TimerCenter(fileURL: url, now: { clock })

        #expect(second.timers.count == 2)
        let tea = second.timers.first { $0.label == "tea" }
        let dough = second.timers.first { $0.label == "dough" }
        // The elapsed timer comes back already fired — silently, no sound.
        #expect(tea?.firedAt != nil)
        #expect(dough?.firedAt == nil)
    }
}
