import Combine
import Foundation
import AppKit

/// Owns the pane's text and keeps it on disk in Application Support.
///
/// Typing triggers a debounced save so persistence never lands on the keystroke
/// path; closing the window or quitting the app flushes immediately, which is
/// what makes the README's first milestone hold: type → quit → relaunch → the
/// text is still there.
final class ScratchStore: ObservableObject {
    static let shared = ScratchStore()

    @Published var text: String

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL = ScratchStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.text = Self.load(from: fileURL)
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Antimatter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("scratchpad.md")
    }

    static func load(from url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Called after every edit; coalesces rapid keystrokes into one write.
    func textDidChange() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Cancels any pending debounced write and saves right now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
