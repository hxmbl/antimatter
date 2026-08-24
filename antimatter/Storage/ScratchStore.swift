import Combine
import Darwin
import Foundation
import AppKit

/// Owns the pane's text and keeps it on disk in Application Support.
///
/// Typing triggers a debounced save so persistence never lands on the keystroke
/// path; closing the window or quitting the app flushes immediately, which is
/// what makes the README's first milestone hold: type → quit → relaunch → the
/// text is still there.
///
/// Writes are not allowed to fail silently: a failed flush records its error
/// in `saveError` (the pane shows a transient hint) and the last good file
/// survives as `<scratchpad>.md.bak` courtesy of `Persistence`. Edits made to
/// the file outside this app are watched for and adopted, so an external
/// editor always wins over this app's next flush.
///
/// Flushes that would write bytes already on disk are skipped — no backup
/// churn, no watcher events, nothing. `lastWritten` tracks what the primary
/// file is believed to contain; it is re-synced from disk whenever an
/// external event lands.
@MainActor
final class ScratchStore: ObservableObject {
    static let shared = ScratchStore()

    @Published var text: String

    /// The most recent flush failure, cleared automatically after a few
    /// seconds and by the next successful flush.
    @Published private(set) var saveError: Error? {
        didSet {
            guard saveError != nil else { return }
            scheduleErrorClear()
        }
    }

    private let fileURL: URL
    private var lastWritten: String?
    private var saveTask: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?
    private var watchSource: DispatchSourceFileSystemObject?
    private var reloadTask: Task<Void, Never>?

    init(fileURL: URL = ScratchStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.text = Persistence.read(from: fileURL) ?? ""
        // Only a readable primary counts as written; if load fell back to
        // the .bak, the first flush must push the rescue out to disk.
        self.lastWritten = Persistence.readPrimary(from: fileURL)
        restartWatching()
    }

    nonisolated static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Antimatter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("scratchpad.md")
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
    /// A failure keeps the pane's text intact on screen and surfaces here;
    /// the previous good copy remains on disk untouched (atomic write).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard text != lastWritten else { return } // disk already agrees

        if let error = Persistence.write(text, to: fileURL) {
            saveError = error
        } else {
            lastWritten = text
            if saveError != nil {
                saveError = nil
            }
        }
        // Atomic writes replace the file, leaving the old watch fd pointing
        // at an orphaned inode — re-arm so external edits stay visible.
        restartWatching()
    }

    /// Drops the transient error hint early (e.g. when a new one replaces it).
    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.saveError = nil
        }
    }

    // MARK: External edits

    /// Watches the scratchpad file (vnode events) while it exists. A failed
    /// open simply means the file isn't there yet; the next flush retries.
    private func restartWatching() {
        watchSource?.cancel()
        watchSource = nil
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }

    /// Coalesces the burst of vnode events one replacement produces.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.adoptExternalChange()
        }
    }

    /// Internal (test-visible): what the vnode watcher does once its
    /// coalescing delay settles.
    func adoptExternalChange() {
        restartWatching()
        if let incoming = Persistence.readPrimary(from: fileURL) {
            // Disk is the truth about what was written, whoever wrote it —
            // our own flush's events land here too and simply sync up.
            lastWritten = incoming
            if incoming != text {
                text = incoming // flows into the editor; its flush is then a no-op
            }
        } else if let rescued = Persistence.read(from: fileURL), rescued != text {
            // Primary vanished or turned unreadable; the .bak still speaks.
            text = rescued // the follow-up flush pushes the rescue onto disk
        }
    }

    deinit {
        watchSource?.cancel()
        reloadTask?.cancel()
    }
}
