import AppKit

/// The pane's text view.
///
/// * A plain click on a link opens it — drag-safe: the click only counts if
///   the mouse barely moved between down and up, so selecting still works.
/// * Escape hides the pane.
/// * The caret jumps over collapsed syntax markers instead of stepping
///   through invisible characters one arrow press at a time.
/// * Dropping an image captures its text (on-device OCR); ⌘F opens the
///   system find bar.
final class PaneTextView: NSTextView {
    var onCancelOperation: (() -> Void)?
    var onDroppedImage: ((NSImage) -> Void)?
    /// Return true when the keystroke was swallowed (the full-screen help
    /// view eats every key except navigation and the way out).
    var onHelpKeyDown: ((NSEvent) -> Bool)?

    private var pendingClick: (location: NSPoint, modifiers: NSEvent.ModifierFlags)?

    // MARK: Accelerated repeat for deletion / navigation
    private var accelerationTimer: Timer?
    private var currentRepeatAction: (() -> Void)?
    private var currentInterval: TimeInterval = 0.35
    private let minInterval: TimeInterval = 0.025
    private var isAccelerating = false
    private var smoothAnimationTimer: Timer?

    /// Routes around any subclass override of `setSelectedRange` without
    /// using `super`, which Swift does not allow inside an escaping closure.
    private func setSelectionRaw(_ range: NSRange) {
        super.setSelectedRange(range)
    }

    private func performSmoothAction(_ action: () -> Void) {
        let startRange = selectedRange()
        action()
        let endRange = selectedRange()
        let startLength = textStorage?.length ?? startRange.length
        guard startRange != endRange || ((textStorage?.length ?? startLength) != startLength) else { return }
        super.setSelectedRange(startRange)
        smoothAnimationTimer?.invalidate()
        let steps = 12
        let interval = 0.008
        var step = 0
        smoothAnimationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            step += 1
            if step >= steps {
                timer.invalidate()
                self.smoothAnimationTimer = nil
                self.setSelectionRaw(endRange)
            } else {
                let progress = Double(step) / Double(steps)
                let newLoc = Int(Double(startRange.location) + Double(endRange.location - startRange.location) * progress)
                self.setSelectionRaw(NSRange(location: max(0, min(newLoc, self.textStorage?.length ?? newLoc)), length: 0))
            }
        }
    }

    private static let acceleratedKeyCodes: Set<UInt16> = [
        51,  // Backspace (deleteBackward)
        117, // Delete (deleteForward)
        123, // Left arrow
        124, // Right arrow
        125, // Down arrow
        126, // Up arrow
        115, // Home
        119  // End
    ]

    private static func isAcceleratedKey(_ event: NSEvent) -> Bool {
        acceleratedKeyCodes.contains(event.keyCode)
    }

    private func actionForAcceleratedKey(_ event: NSEvent) -> (() -> Void)? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        switch event.keyCode {
        case 51: // Backspace
            if cmd { return { [weak self] in self?.performSmoothAction { self?.deleteToBeginningOfLine(nil) } } }
            if opt { return { [weak self] in self?.performSmoothAction { self?.deleteWordBackward(nil) } } }
            return { [weak self] in self?.performSmoothAction { self?.deleteBackward(nil) } }
        case 117: // Delete
            if cmd { return { [weak self] in self?.performSmoothAction { self?.deleteToEndOfLine(nil) } } }
            if opt { return { [weak self] in self?.performSmoothAction { self?.deleteWordForward(nil) } } }
            return { [weak self] in self?.performSmoothAction { self?.deleteForward(nil) } }
        case 123: // Left arrow
            if cmd { return { [weak self] in self?.performSmoothAction { self?.moveToBeginningOfLine(nil) } } }
            if opt { return { [weak self] in self?.performSmoothAction { self?.moveWordLeft(nil) } } }
            return { [weak self] in self?.performSmoothAction { self?.moveLeft(nil) } }
        case 124: // Right arrow
            if cmd { return { [weak self] in self?.performSmoothAction { self?.moveToEndOfLine(nil) } } }
            if opt { return { [weak self] in self?.performSmoothAction { self?.moveWordRight(nil) } } }
            return { [weak self] in self?.performSmoothAction { self?.moveRight(nil) } }
        case 125: // Down arrow
            return { [weak self] in self?.performSmoothAction { self?.moveDown(nil) } }
        case 126: // Up arrow
            return { [weak self] in self?.performSmoothAction { self?.moveUp(nil) } }
        case 115: // Home
            return { [weak self] in self?.performSmoothAction { self?.moveToBeginningOfLine(nil) } }
        case 119: // End
            return { [weak self] in self?.performSmoothAction { self?.moveToEndOfLine(nil) } }
        default: return nil
        }
    }

    /// The pane always builds its own text view with defaults.
    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        // `init(frame:textContainer:)` on recent AppKit defers wiring the
        // text system; leave it unwired and every keystroke dies with a beep
        // (no `textStorage`, so no `interpretKeyEvents`, no insert). Building
        // the stack explicitly and swapping the container in restores it.
        if textStorage == nil {
            let storage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(containerSize: frameRect.size)
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            replaceTextContainer(container)
        }
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // The find bar is the platform's; ⌘F just has to reach it.
        usesFindBar = true
        isIncrementalSearchingEnabled = false
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    // MARK: Link activation

    override func mouseDown(with event: NSEvent) {
        // The floating pane may sit in front of the active app without being
        // key; a click is what hands it typing, so make it key first. Without
        // this, the first click surfaces the window but keystrokes still beep.
        window?.makeKeyAndOrderFront(nil)
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

    // MARK: Image drops → OCR

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        containsImage(sender.draggingPasteboard) ? [.copy] : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let images = imageContents(of: pasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        images.forEach { onDroppedImage?($0) }
        return true
    }

    private func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        !imageContents(of: pasteboard).isEmpty
    }

    private func imageContents(of pasteboard: NSPasteboard) -> [NSImage] {
        var images: [NSImage] = []
        if let dropped = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            images.append(contentsOf: dropped)
        }
        if images.isEmpty,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            images.append(contentsOf: urls.compactMap { NSImage(contentsOf: $0) })
        }
        return images
    }

    // MARK: Context menu — the escape hatch for menu-bar mode

    /// Without a menu bar (Dock icon hidden) there is no Settings item and
    /// no ⌘Q; the pane's right-click menu is what keeps accessory mode
    /// escapable.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let appDelegate = NSApplication.shared.delegate as? AppDelegate
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: "")
        settings.target = appDelegate
        menu.addItem(settings)
        let reveal = NSMenuItem(title: "Reveal Scratchpad in Finder", action: #selector(revealScratchpad(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(NSMenuItem(title: "Quit Antimatter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func revealScratchpad(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([ScratchStore.defaultFileURL()])
    }

    // MARK: Help view keystroke interception

    private func startAcceleration(for event: NSEvent) {
        guard let action = actionForAcceleratedKey(event) else { return }
        isAccelerating = true
        currentInterval = 0.35
        currentRepeatAction = action
        currentRepeatAction?()
        scheduleNextAcceleration()
    }

    private func scheduleNextAcceleration() {
        guard isAccelerating else { return }
        accelerationTimer?.invalidate()
        accelerationTimer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: false) { [weak self] timer in
            guard let self = self, self.isAccelerating else {
                timer.invalidate()
                return
            }
            self.currentRepeatAction?()
            self.currentInterval = max(self.minInterval, self.currentInterval * 0.85)
            self.scheduleNextAcceleration()
        }
    }

    private func stopAcceleration() {
        isAccelerating = false
        accelerationTimer?.invalidate()
        accelerationTimer = nil
        currentRepeatAction = nil
    }

    override func keyDown(with event: NSEvent) {
        if onHelpKeyDown?(event) == true { return }
        if Self.isAcceleratedKey(event) {
            if event.isARepeat {
                // System repeats are ignored; our timer handles acceleration.
                return
            }
            startAcceleration(for: event)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if Self.isAcceleratedKey(event) {
            stopAcceleration()
            return
        }
        super.keyUp(with: event)
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
