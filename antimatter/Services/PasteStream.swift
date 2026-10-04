import AppKit
import Combine

/// Return on `.paste` starts streaming: clipboard copies land in the note
/// until dismissed.
@MainActor
final class PasteStream: ObservableObject {
    static let shared = PasteStream()

    @Published private(set) var isStreaming = false

    /// The note copies are appended to. `.paste` used to hard-code
    /// `NoteStore.shared`, so a ⌘N window streamed into the *shared* window's
    /// note instead of the one on screen. Pass the window-local store; `nil`
    /// (the default) resolves to `.shared` for callers that have none.
    private var targetStore: NoteStore = .shared

    private var pollTask: Task<Void, Never>?
    private var lastChangeCount = 0

    /// Starts (or re-targets) the stream. Re-targeting while a stream is
    /// already running is deliberate: typing `.paste` in a second window
    /// should send later copies there rather than keep writing to the first.
    func startStreaming(into store: NoteStore? = nil) {
        targetStore = store ?? .shared
        guard !isStreaming else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        isStreaming = true
        DebugLog.log("paste stream started")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                self.adoptClipboardIfNew()
            }
        }
    }

    func stopStreaming() {
        pollTask?.cancel()
        pollTask = nil
        isStreaming = false
    }

    private func adoptClipboardIfNew() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let copied = pasteboard.string(forType: .string), !copied.isEmpty else { return }
        adoptClipboardText(copied)
    }

    /// Appends one clipboard payload to the streaming note. Split out from the
    /// pasteboard polling so the write path is exercisable without touching the
    /// real clipboard.
    func adoptClipboardText(_ copied: String) {
        guard !copied.isEmpty else { return }
        let store = targetStore
        var note = store.activeNote
        note.text += (note.text.isEmpty ? "" : "\n") + copied
        store.activeNote = note
        DebugLog.log("paste adopted — \(copied.count) chars")
    }
}