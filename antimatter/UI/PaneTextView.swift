import AppKit

/// The pane's text view.
///
/// * A plain click on a link opens it — drag-safe: the click only counts if
///   the mouse barely moved between down and up, so selecting still works.
/// * Escape hides the pane.
/// * The caret jumps over collapsed syntax markers instead of stepping
///   through invisible characters one arrow press at a time.
final class PaneTextView: NSTextView {
    var onCancelOperation: (() -> Void)?

    private var pendingClick: (location: NSPoint, modifiers: NSEvent.ModifierFlags)?

    // MARK: Link activation

    override func mouseDown(with event: NSEvent) {
        pendingClick = (event.locationInWindow, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { pendingClick = nil }
        guard let down = pendingClick,
              event.clickCount == 1,
              down.modifiers.subtracting([.capsLock, .function]).isEmpty,
              abs(event.locationInWindow.x - down.location.x) < 4,
              abs(event.locationInWindow.y - down.location.y) < 4,
              let url = link(at: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func link(at index: Int) -> URL? {
        guard let storage = textStorage else { return nil }
        // The insertion index can snap just past a glyph near an edge;
        // falling back one character keeps clicks inside the link reliable.
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            if let url = storage.attribute(.link, at: candidate, effectiveRange: nil) as? URL {
                return url
            }
        }
        return nil
    }

    // MARK: Escape hides the pane

    override func cancelOperation(_ sender: Any?) {
        if let onCancelOperation {
            onCancelOperation()
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: Caret over collapsed markers

    override func moveRight(_ sender: Any?) {
        if let target = jumpTarget(step: 1) {
            setSelectedRange(NSRange(location: target, length: 0))
        } else {
            super.moveRight(sender)
        }
    }

    override func moveLeft(_ sender: Any?) {
        if let target = jumpTarget(step: -1) {
            setSelectedRange(NSRange(location: target, length: 0))
        } else {
            super.moveLeft(sender)
        }
    }

    /// Returns a caret position past the neighbouring run of collapsed
    /// markers when moving would otherwise step into one, else nil.
    private func jumpTarget(step: Int) -> Int? {
        guard let storage = textStorage else { return nil }
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let location = selection.location
        switch step {
        case 1:
            guard location < storage.length, isCollapsed(at: location, in: storage) else { return nil }
            var target = location
            while target < storage.length, isCollapsed(at: target, in: storage) {
                var effective = NSRange()
                _ = storage.attributes(at: target, effectiveRange: &effective)
                target = NSMaxRange(effective)
            }
            return target
        case -1:
            guard location > 0, isCollapsed(at: location - 1, in: storage) else { return nil }
            var target = location
            while target > 0, isCollapsed(at: target - 1, in: storage) {
                var effective = NSRange()
                _ = storage.attributes(at: target - 1, effectiveRange: &effective)
                target = effective.location
            }
            return target
        default:
            return nil
        }
    }

    /// Collapsed markers are rendered with a 1pt font; nothing legitimate
    /// is ever that small.
    private func isCollapsed(at index: Int, in storage: NSTextStorage) -> Bool {
        (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont).map { $0.pointSize <= 2 } ?? false
    }
}
