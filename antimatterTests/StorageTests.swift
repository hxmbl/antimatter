import Foundation
import SwiftUI
import Testing
@testable import antimatter

@MainActor
struct NoteStoreTests {

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("notes.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    @Test func missingFileLoadsAsEmpty() {
        let store = NoteStore(fileURL: tempURL())
        #expect(store.notes.count == 1)
        #expect(store.activeNote.text == "")
    }

    @Test func createInsertsNewestFirstAndActivates() {
        let store = NoteStore(fileURL: tempURL())
        let first = store.create(text: "alpha")
        let second = store.create(text: "beta")
        #expect(store.notes.count == 2)
        #expect(store.notes[0].id == second.id)
        #expect(store.activeNoteID == second.id)
        store.cycleNote(direction: 1)
        #expect(store.activeNoteID == first.id)
    }

    @Test func textRoundTripsThroughDisk() {
        let url = tempURL()
        let source = "# scratch\n- [x] milk\n384 * 27"
        let writer = NoteStore(fileURL: url)
        var note = writer.activeNote
        note.text = source
        writer.activeNote = note
        writer.flush()
        let reader = NoteStore(fileURL: url)
        #expect(reader.activeNote.text == source)
    }

    @Test func flushWritesImmediatelyEvenWithPendingDebounce() throws {
        let url = tempURL()
        let store = NoteStore(fileURL: url)
        var note = store.activeNote
        note.text = "typed just now"
        store.activeNote = note
        store.activeText.wrappedValue = "typed just now"   // triggers debounced write…
        store.flush()                                      // …but quit must not wait for it
        let onDisk = try JSONDecoder().decode(NoteStore.Snapshot.self, from: Data(contentsOf: url))
        #expect(onDisk.notes.contains { $0.text == "typed just now" })
    }

    @Test func deleteMovesNoteToTrashAndAdvancesActive() {
        let store = NoteStore(fileURL: tempURL())
        let first = store.create(text: "keep me")
        let doomed = store.create(text: "delete me")
        store.delete(doomed)
        #expect(!store.notes.contains { $0.id == doomed.id })
        #expect(store.trash.contains { $0.id == doomed.id })
        #expect(store.activeNoteID == first.id)
    }

    @Test func restoreBringsNoteBackFromVoid() {
        let store = NoteStore(fileURL: tempURL())
        let doomed = store.create(text: "resurrect me")
        store.delete(doomed)
        store.restore(doomed)
        #expect(store.notes.contains { $0.id == doomed.id })
        #expect(!store.trash.contains { $0.id == doomed.id })
    }

    @Test func emptyVoidClearsTrash() {
        let store = NoteStore(fileURL: tempURL())
        let doomed = store.create(text: "gone")
        store.delete(doomed)
        store.emptyVoid()
        #expect(store.trash.isEmpty)
    }

    @Test func cycleNoteWrapsInBothDirections() {
        let store = NoteStore(fileURL: tempURL())
        let first = store.create(text: "first")
        let second = store.create(text: "second")
        let third = store.create(text: "third")
        #expect(store.activeNoteID == third.id)
        store.cycleNote(direction: 1)
        #expect(store.activeNoteID == second.id)
        store.cycleNote(direction: 1)
        #expect(store.activeNoteID == first.id)
        store.cycleNote(direction: -1)
        #expect(store.activeNoteID == second.id)
    }

    @Test func promoteToSlotMarksNoteAndReplacesExistingSlot() {
        let store = NoteStore(fileURL: tempURL())
        let a = store.create(text: "slot a")
        store.promoteToSlot(a, at: 2)
        #expect(store.notes.first { $0.id == a.id }?.isSlot == true)
        #expect(store.notes.first { $0.id == a.id }?.slotIndex == 2)
        #expect(store.slotNotes().count == 1)

        let b = store.create(text: "slot b")
        store.promoteToSlot(b, at: 2)
        #expect(!store.notes.contains { $0.id == a.id })
        #expect(store.slotNotes().count == 1)
        #expect(store.slotNotes()[0].id == b.id)
    }

    @Test func promoteToSlotRejectsOutOfRange() {
        let store = NoteStore(fileURL: tempURL())
        let a = store.create(text: "no slot")
        store.promoteToSlot(a, at: 9)
        #expect(store.notes.first { $0.id == a.id }?.isSlot == false)
        store.promoteToSlot(a, at: -1)
        #expect(store.notes.first { $0.id == a.id }?.isSlot == false)
    }

    @Test func noteForSlotCreatesAndIsIdempotent() {
        let store = NoteStore(fileURL: tempURL())
        let note = store.note(forSlot: 3)
        #expect(note.isSlot && note.slotIndex == 3)
        #expect(store.slotNotes().map(\.id) == [note.id])
        let pinnedCount = store.notes.count
        // Repeat presses return the same pinned note instead of creating more.
        let again = store.note(forSlot: 3)
        #expect(again.id == note.id)
        #expect(store.notes.count == pinnedCount)
        #expect(store.slotNotes().count == 1)
        #expect(store.activeNoteID == note.id)
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
            id: UUID(), label: "stale", name: nil, duration: 10,
            endDate: clock.addingTimeInterval(-7_200), createdAt: clock.addingTimeInterval(-7_210),
            firedAt: clock.addingTimeInterval(-7_200), fullScreen: false
        )
        try JSONEncoder().encode([stale]).write(to: url)

        let reloaded = TimerCenter(fileURL: url, now: { clock })
        #expect(reloaded.timers.isEmpty)
    }

    @Test func corruptTimersJSONFallsBackToTheBackup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-timers-\(UUID().uuidString).json")
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let tea = ActiveTimer(
            id: UUID(), label: "tea", name: nil, duration: 60,
            endDate: clock.addingTimeInterval(60), createdAt: clock, firedAt: nil,
            fullScreen: false
        )
        // Last good generation lives in the .bak; the primary is garbage.
        try JSONEncoder().encode([tea]).write(to: Persistence.backupURL(for: url))
        try Data([0xFF]).write(to: url)

        let reloaded = TimerCenter(fileURL: url, now: { clock })
        #expect(reloaded.timers.map(\.label) == ["tea"])
    }

    @Test func recoveryPersistDoesNotBuryTheGoodBackupUnderGarbage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-timers-\(UUID().uuidString).json")
        let backup = Persistence.backupURL(for: url)
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let tea = ActiveTimer(
            id: UUID(), label: "tea", name: nil, duration: 60,
            endDate: clock.addingTimeInterval(60), createdAt: clock, firedAt: nil,
            fullScreen: false
        )
        try JSONEncoder().encode([tea]).write(to: backup)
        try Data([0xFF]).write(to: url)   // primary is garbage

        let center = TimerCenter(fileURL: url, now: { clock })
        #expect(center.timers.map(\.label) == ["tea"])   // recovered from bak
        center.dismiss(center.timers[0].id)              // forces a persist…

        // …which must not rotate the undecodable primary over the good bak.
        let bakTimers = try JSONDecoder().decode([ActiveTimer].self, from: Data(contentsOf: backup))
        #expect(bakTimers.map(\.label) == ["tea"])
        #expect((try? JSONDecoder().decode([ActiveTimer].self, from: Data(contentsOf: url)))?.isEmpty == true)
    }

    @Test func missingTimersFilesLoadEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-timers-\(UUID().uuidString).json")
        let center = TimerCenter(fileURL: url, now: Date.init)
        #expect(center.timers.isEmpty)
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

    @Test func pomodoroSurvivesRelaunchOnItsWorkPhase() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let url = tempFile()

        let first = TimerCenter(fileURL: url, now: { clock })
        first.startPomodoro(work: 60, rest: 10, cycles: 4)

        #expect(first.timers.map(\.label) == ["Pomodoro 1/4 — Work"])

        clock = clock.addingTimeInterval(5)   // a few seconds later, app relaunches
        let second = TimerCenter(fileURL: url, now: { clock })

        // The work phase comes back active, not dismissed and not fired.
        #expect(second.timers.map(\.label) == ["Pomodoro 1/4 — Work"])
        #expect(second.timers[0].firedAt == nil)
        #expect(second.timers[0].endDate == clock.addingTimeInterval(55))
    }

    @Test func cancelAllClearsPersistedPomodoro() {
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let url = tempFile()

        let center = TimerCenter(fileURL: url, now: { clock })
        center.startPomodoro(work: 60, rest: 10, cycles: 4)
        center.cancelAll()

        #expect(center.timers.isEmpty)
        let reloaded = TimerCenter(fileURL: url, now: { clock })
        #expect(reloaded.timers.isEmpty)
    }
}

@MainActor
struct StopwatchCenterTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-stopwatches-\(UUID().uuidString).json")
    }

    @Test func startTicksWithTheClockAndStopFreezes() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let center = StopwatchCenter(fileURL: tempFile(), now: { clock })
        #expect(center.start(label: "pomodoro"))
        let id = center.stopwatches[0].id
        #expect(center.elapsed(center.stopwatches[0]) == 0)

        clock = clock.addingTimeInterval(90)
        #expect(center.elapsed(center.stopwatches[0]) == 90)

        center.stop(id)
        clock = clock.addingTimeInterval(30)   // the clock keeps moving…
        #expect(center.elapsed(center.stopwatches[0]) == 90)   // …the reading is frozen
    }

    @Test func stopwatchesSurviveRelaunchAndKeepCounting() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let url = tempFile()
        let first = StopwatchCenter(fileURL: url, now: { clock })
        first.start(label: "dough")
        first.start(label: "soup")

        clock = clock.addingTimeInterval(300)   // the app was closed for five minutes
        let second = StopwatchCenter(fileURL: url, now: { clock })
        #expect(second.stopwatches.count == 2)
        let soup = second.stopwatches.first { $0.label == "soup" }
        #expect(soup != nil)
        #expect(second.elapsed(soup!) == 300)
    }

    @Test func longStoppedChipsArePrunedOnLoad() throws {
        let url = tempFile()
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let old = ActiveStopwatch(
            id: UUID(), label: "old",
            startedAt: clock.addingTimeInterval(-7_200),
            createdAt: clock.addingTimeInterval(-7_200),
            stoppedAt: clock.addingTimeInterval(-7_200))
        let live = ActiveStopwatch(
            id: UUID(), label: "live",
            startedAt: clock, createdAt: clock, stoppedAt: nil)
        try JSONEncoder().encode([old, live]).write(to: url)

        let reloaded = StopwatchCenter(fileURL: url, now: { clock })
        #expect(reloaded.stopwatches.map(\.label) == ["live"])
    }

    @Test func dismissAndCancelClearEverything() {
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let url = tempFile()
        let center = StopwatchCenter(fileURL: url, now: { clock })
        center.start(label: "a")
        center.start(label: "b")
        #expect(center.stopwatches.count == 2)

        center.dismiss(center.stopwatches[0].id)
        #expect(center.stopwatches.count == 1)

        center.cancelAll()
        #expect(center.stopwatches.isEmpty)

        let reloaded = StopwatchCenter(fileURL: url, now: { clock })
        #expect(reloaded.stopwatches.isEmpty)
    }
}

// MARK: - Theme colours

@MainActor
struct ThemeHexTests {

    /// `#abc` used to hit the `default` branch and render as pure white,
    /// because only `hex.count == 6` was understood.
    @Test func threeDigitHexExpandsByDoublingEachDigit() {
        let c = HexColor.components(from: "#abc")
        #expect(c?.red == Double(0xAA) / 255)
        #expect(c?.green == Double(0xBB) / 255)
        #expect(c?.blue == Double(0xCC) / 255)
        #expect(c?.alpha == 1)

        let color = NSColor(hex: "#abc").usingColorSpace(.sRGB)
        #expect(abs((color?.redComponent ?? 0) - Double(0xAA) / 255) < 0.002)
        #expect(abs((color?.greenComponent ?? 0) - Double(0xBB) / 255) < 0.002)
        #expect(abs((color?.blueComponent ?? 0) - Double(0xCC) / 255) < 0.002)
    }

    @Test func sixDigitHexIsUnchanged() {
        let c = HexColor.components(from: "#1C1C1E")
        #expect(c?.red == Double(0x1C) / 255)
        #expect(c?.green == Double(0x1C) / 255)
        #expect(c?.blue == Double(0x1E) / 255)
        #expect(c?.alpha == 1)
    }

    /// The alpha-carrying forms were broken the same way `#abc` was.
    @Test func shortFormWithAlphaAndLongFormWithAlphaParse() {
        let four = HexColor.components(from: "#f00a")
        #expect(four?.red == 1)
        #expect(four?.green == 0)
        #expect(four?.blue == 0)
        #expect(abs((four?.alpha ?? 0) - Double(0xAA) / 255) < 0.002)

        let eight = HexColor.components(from: "#0000FF80")
        #expect(eight?.red == 0)
        #expect(eight?.green == 0)
        #expect(eight?.blue == 1)
        #expect(abs((eight?.alpha ?? 0) - Double(0x80) / 255) < 0.002)

        let ns = NSColor(hex: "#0000FF80").usingColorSpace(.sRGB)
        #expect(abs((ns?.alphaComponent ?? 0) - Double(0x80) / 255) < 0.002)
    }

    @Test func aLeadingHashIsOptionalAndJunkIsRejected() {
        #expect(HexColor.components(from: "abc") == HexColor.components(from: "#abc"))
        #expect(HexColor.components(from: " #abc ") == HexColor.components(from: "#abc"))
        // Unsupported shapes fall through to the caller's white fallback.
        #expect(HexColor.components(from: "") == nil)
        #expect(HexColor.components(from: "#12") == nil)
        #expect(HexColor.components(from: "#12345") == nil)
        #expect(HexColor.components(from: "#1234567") == nil)
        #expect(HexColor.components(from: "#123456789") == nil)
        #expect(HexColor.components(from: "#gggggg") == nil)
        let fallback = NSColor(hex: "not a colour").usingColorSpace(.sRGB)
        #expect(abs((fallback?.redComponent ?? 0) - 1) < 0.002)
    }

    @Test func everyBuiltInThemeColourParses() {
        for theme in PaneTheme.builtIn {
            for hex in [theme.backgroundColor, theme.textColor, theme.accentColor, theme.tintColor] {
                #expect(HexColor.components(from: hex) != nil,
                        "\(theme.id) has an unparseable colour \"\(hex)\" — it would render as pure white")
            }
        }
    }
}

// MARK: - Paste stream

@MainActor
struct PasteStreamTests {

    private func tempStore() -> NoteStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antimatter-paste-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("notes.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return NoteStore(fileURL: url)
    }

    /// `.paste` hard-coded `NoteStore.shared`, so a ⌘N window streamed into
    /// another window's note.
    @Test func pasteAppendsToTheStoreItWasStartedWith() {
        let target = tempStore()
        let stream = PasteStream.shared
        defer { stream.stopStreaming() }

        stream.startStreaming(into: target)
        stream.adoptClipboardText("copied text")
        #expect(target.activeNote.text == "copied text")
    }

    @Test func appendingContinuesTheStreamedNoteOnOneLine() {
        let target = tempStore()
        let stream = PasteStream.shared
        defer { stream.stopStreaming() }

        stream.startStreaming(into: target)
        stream.adoptClipboardText("first")
        stream.adoptClipboardText("second")
        #expect(target.activeNote.text == "first\nsecond")
        // Empty clipboard payloads are ignored rather than appending a blank line.
        stream.adoptClipboardText("")
        #expect(target.activeNote.text == "first\nsecond")
    }

    @Test func aSecondPasteRetargetsARunningStream() {
        let first = tempStore()
        let second = tempStore()
        let stream = PasteStream.shared
        defer { stream.stopStreaming() }

        stream.startStreaming(into: first)
        stream.adoptClipboardText("into the first window")
        #expect(first.activeNote.text == "into the first window")

        stream.startStreaming(into: second)
        stream.adoptClipboardText("into the second window")
        #expect(second.activeNote.text == "into the second window")
        #expect(first.activeNote.text == "into the first window")
    }

    @Test func stoppingClearsTheStreamingFlag() {
        let stream = PasteStream.shared
        defer { stream.stopStreaming() }
        stream.startStreaming(into: tempStore())
        #expect(stream.isStreaming)
        stream.stopStreaming()
        #expect(!stream.isStreaming)
        // Idempotent: a second stop must not trap or resurrect the task.
        stream.stopStreaming()
        #expect(!stream.isStreaming)
    }
}

// MARK: - Pane window configuration

/// Serialized: it mutates `pane.displayMode` and a process-wide memo.
@MainActor
@Suite(.serialized)
struct WindowConfiguratorTests {

    private func withDisplayMode<T>(_ mode: String, _ body: () -> T) -> T {
        let previous = UserDefaults.standard.string(forKey: "pane.displayMode")
        UserDefaults.standard.set(mode, forKey: "pane.displayMode")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "pane.displayMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "pane.displayMode")
            }
        }
        return body()
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
    }

    /// Configuration used to be scheduled from `makeNSView`, where
    /// `view.window` is always nil, so the *first* pass never ran and the
    /// window only picked up its settings a runloop later.
    @Test func theFirstDockConfigurationActuallyApplies() {
        withDisplayMode("dock") {
            let window = makeWindow()
            WindowConfigurator.configure(window)
            #expect(window.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true)
            #expect(window.maxSize == NSSize(width: PaneStyle.windowMaxWidth, height: PaneStyle.windowMaxHeight))
            #expect(window.minSize == NSSize(width: PaneStyle.windowMinWidth, height: PaneStyle.windowMinHeight))
            #expect(window.isMovableByWindowBackground)
        }
    }

    @Test func aNonDockWindowIsStrippedOfTrafficLightsAndOrderedOut() {
        withDisplayMode("menuBar") {
            let window = makeWindow()
            WindowConfigurator.configure(window)
            #expect(window.styleMask.contains(.closable) == false)
            #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
            #expect(window.isVisible == false)
        }
    }

    /// Switching modes must re-configure the same window rather than trusting
    /// the memo from the previous mode.
    @Test func switchingModesReconfiguresTheSameWindow() {
        let window = makeWindow()
        withDisplayMode("menuBar") {
            WindowConfigurator.configure(window)
            #expect(window.styleMask.contains(.closable) == false)
        }
        withDisplayMode("dock") {
            WindowConfigurator.configure(window)
            #expect(window.styleMask.contains(.closable) == true)
            #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
            #expect(window.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true)
        }
    }

    /// The memo used to be keyed by `ObjectIdentifier` alone, which is recycled
    /// after deallocation, and it was never pruned. A live window's entry must
    /// always belong to that window, and dead entries must not accumulate.
    @Test func theConfigurationMemoNeverOutlivesItsWindows() {
        withDisplayMode("dock") {
            var survivors: [NSWindow] = []
            for _ in 0..<3 {
                let window = makeWindow()
                WindowConfigurator.configure(window)
                survivors.append(window)
            }
            #expect(WindowConfigurator.deadEntryCount == 0)
            #expect(survivors.allSatisfy {
                $0.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true
            })
            #expect(Set(survivors.map { ObjectIdentifier($0) }).count == survivors.count)

            withExtendedLifetime(survivors) {
                WindowConfigurator.pruneDeadEntries()
            }
            #expect(WindowConfigurator.deadEntryCount == 0)
        }
    }

    /// A window that is gone must leave nothing behind: its entry is dropped on
    /// the next pass instead of being inherited by a new window whose
    /// `ObjectIdentifier` happens to be the same.
    @Test func aWindowThatIsGoneLeavesNoConfigurationBehind() {
        withDisplayMode("dock") {
            // Start from a clean table so leftovers from an earlier test in this
            // suite cannot inflate the count below.
            WindowConfigurator.pruneDeadEntries()
            #expect(WindowConfigurator.deadEntryCount == 0)

            autoreleasepool {
                let transient = makeWindow()
                WindowConfigurator.configure(transient)
                #expect(transient.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true)
            }
            #expect(WindowConfigurator.deadEntryCount == 1)

            let fresh = makeWindow()
            WindowConfigurator.configure(fresh)
            #expect(WindowConfigurator.deadEntryCount == 0)
            #expect(fresh.identifier?.rawValue.hasPrefix(PaneStyle.windowIdentifier) == true)
            withExtendedLifetime(fresh) {}
        }
    }

    @Test func configuringNoWindowIsANoOp() {
        WindowConfigurator.configure(nil)
    }
}

// MARK: - Pane windows

@MainActor
struct PaneWindowTests {

    /// ⌘N gives every extra window a slot-scoped frame-autosave name, which is
    /// what keeps the saved rect readable instead of growing an entry per
    /// window ever opened.
    @Test func frameAutosaveNamesAreSlotScopedAndUnique() {
        #expect(WindowManager.maxWindowSlots > 0)
        #expect(WindowManager.frameAutosaveName(for: 0) == "\(PaneStyle.frameAutosaveName).0")
        let names = (0..<WindowManager.maxWindowSlots).map { WindowManager.frameAutosaveName(for: $0) }
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix(PaneStyle.frameAutosaveName) })
    }

    @Test func paneLookupIgnoresNonPaneWindows() {
        let pane = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        pane.identifier = NSUserInterfaceItemIdentifier("\(PaneStyle.windowIdentifier).3")
        let stranger = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        stranger.identifier = NSUserInterfaceItemIdentifier("some.other.window")

        #expect(WindowManager.isPane(pane))
        #expect(WindowManager.isPane(stranger) == false)

        let identifierless = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        #expect(WindowManager.isPane(identifierless) == false)
    }

    /// The free slot must always land inside the bounded range, so the saved
    /// frame set can never grow past `maxWindowSlots`.
    @Test func theFreeSlotIsAlwaysInRange() {
        for _ in 0..<5 {
            let slot = WindowManager.freeSlot()
            #expect(slot >= 0)
            #expect(slot < WindowManager.maxWindowSlots)
        }
    }
}

/// Settings offers Dock / Menu Bar / Dropdown tags; a tag that drifts from
/// `PaneStyle.DisplayMode` becomes a dead mode only reachable by hand-editing
/// defaults.
@MainActor
struct DisplayModeTests {
    @Test func everyCaseRoundTripsThroughItsRawValue() {
        for mode in PaneStyle.DisplayMode.allCases {
            #expect(PaneStyle.DisplayMode(rawValue: mode.rawValue) == mode)
        }
        #expect(PaneStyle.DisplayMode.allCases.count == 3)
        #expect(PaneStyle.DisplayMode(rawValue: "dropdown") == .dropdown)
        #expect(PaneStyle.DisplayMode(rawValue: "not-a-mode") == nil)
    }
}
