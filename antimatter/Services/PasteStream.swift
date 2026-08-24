import AppKit
import Combine

/// Return on `.paste` starts streaming: every subsequent clipboard copy
/// lands in the note as plain text until dismissed. Polling the pasteboard
/// change count is the whole mechanism — no polling of contents, no
/// permissions, nothing networked.
@MainActor
final class PasteStream: ObservableObject {
    static let shared = PasteStream()

    @Published private(set) var isStreaming = false

    private var pollTask: Task<Void, Never>?
    private var lastChangeCount = 0

    func startStreaming() {
        guard !isStreaming else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        isStreaming = true
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
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
        ScratchStore.shared.text += "\n" + copied
        // The pane's SwiftUI onChange only exists while the window does;
        // streaming with the pane closed must still reach the disk.
        ScratchStore.shared.textDidChange()
    }
}
