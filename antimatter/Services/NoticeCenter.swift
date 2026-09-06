import Combine
import Foundation

/// Transient user-facing notices rendered as chips at the top of the pane,
/// auto-clearing after a few seconds. Anything a command wants to say without
/// polluting the note — a clamped duration, an unrecognised dot-command, a
/// missing argument, a copied answer — speaks here instead of failing
/// silently.
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    @Published private(set) var notice: String? {
        didSet {
            guard notice != nil else { return }
            noticeClearTask?.cancel()
            noticeClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.notice = nil
            }
        }
    }

    private var noticeClearTask: Task<Void, Never>?

    func show(_ message: String) {
        notice = message
    }
}