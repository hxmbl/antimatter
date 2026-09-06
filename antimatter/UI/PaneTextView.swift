import AppKit
import QuartzCore

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

    // MARK: Accelerated repeat for navigation
    private func userBaseInterval() -> TimeInterval {
        // macOS system settings: KeyRepeat (ticks/60) default ~6, InitialKeyRepeat default ~15
        let initialRepeat = UserDefaults.standard.object(forKey: "InitialKeyRepeat") as? Int ?? 15
        // Use initial delay as the user's deliberate base speed, converted to seconds
        let base = max(1, initialRepeat > 0 ? initialRepeat : 15)
        return TimeInterval(base) / 60.0
    }

    private func userMinInterval() -> TimeInterval {
        userBaseInterval() / 1.6
    }

    private var accelerationTimer: Timer?
    private var currentRepeatAction: (() -> Void)?
    private var currentInterval: TimeInterval = 0.35
    private var isAccelerating = false

    // MARK: Visual-only caret glide
    //
    // The real NSTextView selection/caret is authoritative and always moves
    // to its final spot immediately — editing, IME, undo, accessibility and
    // the delegate all see the true position. The animation below is a pure
    // visual overlay: it glides/stretches a "ghost" caret between where the
    // caret was and where it now is, drawn on top of the text. It never
    // touches `setSelectedRange`, so while the ghost sweeps, the actual
    // insertion point is already the destination. Small moves glide normally;
    // larger gaps glide faster over the distance.

    private struct Glide {
        var from: CGRect
        var to: CGRect
        var startTime: CFTimeInterval
        var duration: CFTimeInterval
    }

    private var glide: Glide?
    private var glideTimer: Timer?
    private var selectionBeforeMouseDown = NSRange(location: 0, length: 0)
    private var windowObserverToken: NSObjectProtocol?
    private var inputSessionTimer: Timer?

    private var caretIsActive: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    /// Kicks off (or retargets) a ghost glide from `fromLocation` to
    /// `toLocation`. Small moves earn a normal glide; larger gaps glide
    /// faster over the distance so the animation never feels sluggish.
    private func glideCaret(from fromLocation: Int, to toLocation: Int) {
        // Only when a real, focused, collapsed caret is drawn — never while
        // composing an IME string, never while a selection is visible.
        guard caretIsActive, selectedRange().length == 0, !hasMarkedText() else {
            cancelGlide()
            return
        }
        guard fromLocation != toLocation else {
            cancelGlide()
            return
        }
        let fromRect = caretRect(forCharacterIndex: fromLocation)
        let toRect = caretRect(forCharacterIndex: toLocation)
        let distance = hypot(toRect.midX - fromRect.midX, toRect.midY - fromRect.midY)
        startGlide(from: fromRect, to: toRect, distance: distance)
    }

    private func startGlide(from fromRect: CGRect, to toRect: CGRect, distance: CGFloat) {
        cancelGlide()
        // Keep duration roughly constant; larger gaps naturally get covered faster
        // (speed = distance/duration). Very large jumps get slightly shorter duration.
        let baseDuration: CFTimeInterval = 0.15
        let distanceFactor = min(distance / 1000.0, 0.3) // Minimal scaling for huge jumps
        let duration = baseDuration / (1.0 + distanceFactor)
        glide = Glide(from: fromRect, to: toRect, startTime: CACurrentMediaTime(), duration: duration)
        invalidateGlideArea()
        glideTimer?.invalidate()
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceGlide()
        }
        // Begin a minimal input session to suppress NSInputAnalytics warning
        beginInputSession()
    }

    private func advanceGlide() {
        // A selection, IME composition, or focus change that slips in mid-glide
        // drops the ghost immediately — the real text system owns the caret.
        guard caretIsActive, selectedRange().length == 0, !hasMarkedText() else {
            cancelGlide()
            return
        }
        guard let glide = glide else { return }
        let t = (CACurrentMediaTime() - glide.startTime) / glide.duration
        if t >= 1 {
            finishGlide()
        } else {
            invalidateGlideArea()
        }
    }

    private func finishGlide() {
        guard glide != nil else { return }
        invalidateGlideArea()
        glide = nil
        glideTimer?.invalidate()
        glideTimer = nil
        endInputSession()
    }

    /// Cancels any in-flight glide so no stale ghost lingers (focus loss,
    /// large jump, selection, IME). The real caret is always ready to draw.
    private func cancelGlide() {
        guard glide != nil || glideTimer != nil else { return }
        invalidateGlideArea()
        glide = nil
        glideTimer?.invalidate()
        glideTimer = nil
        endInputSession()
    }

    private func invalidateGlideArea() {
        guard let glide = glide else { return }
        setNeedsDisplay(glide.from.union(glide.to).insetBy(dx: -6, dy: -4))
    }

    private func currentGlideRect() -> CGRect? {
        guard let glide = glide else { return nil }
        let t = min(max((CACurrentMediaTime() - glide.startTime) / glide.duration, 0), 1)
        let eased = 1 - pow(1 - t, 3)
        return CGRect(
            x: glide.from.minX + (glide.to.minX - glide.from.minX) * eased,
            y: glide.from.minY + (glide.to.minY - glide.from.minY) * eased,
            width: glide.to.width,
            height: glide.from.height + (glide.to.height - glide.from.height) * eased
        )
    }
    
    /// Minimal input session management to suppress NSInputAnalytics warnings
    private func beginInputSession() {
        inputSessionTimer?.invalidate()
        inputSessionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.endInputSession()
        }
    }
    
    private func endInputSession() {
        inputSessionTimer?.invalidate()
        inputSessionTimer = nil
    }

    /// The caret rectangle (in the text view's drawing space) for a character
    /// index, derived from the layout manager the same way AppKit does.
    private func caretRect(forCharacterIndex index: Int) -> CGRect {
        guard let layoutManager = layoutManager else { return .zero }
        let length = textStorage?.length ?? 0
        let clamped = min(max(index, 0), length)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clamped)
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let origin = textContainerOrigin
        let width: CGFloat = 2
        return CGRect(x: origin.x + glyphLocation.x, y: origin.y + lineRect.minY, width: width, height: lineRect.height)
    }

    /// Suppresses the real caret while the ghost is sweeping (so the two never
    /// overlap) and hands the authoritative destination rect over to the glide.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if glide != nil, caretIsActive, selectedRange().length == 0, !hasMarkedText() {
            glide?.to = rect
            return
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCaretGlide()
    }

    /// Draws the gliding/stretching ghost caret on top of the text. Whenever
    /// it is not animating the real AppKit caret shows through untouched.
    private func drawCaretGlide() {
        guard caretIsActive, selectedRange().length == 0, !hasMarkedText(),
              let glide = glide, let head = currentGlideRect() else { return }
        let color = insertionPointColor ?? .labelColor
        // A tapered belt from the source caret to the moving head gives the
        // terminal-like stretch as it sweeps toward the new position.
        let base = glide.from
        let belt = NSBezierPath()
        belt.move(to: CGPoint(x: base.minX, y: base.minY))
        belt.line(to: CGPoint(x: head.minX, y: head.minY))
        belt.line(to: CGPoint(x: head.minX, y: head.maxY))
        belt.line(to: CGPoint(x: base.minX, y: base.maxY))
        belt.close()
        color.withAlphaComponent(0.45).setFill()
        belt.fill()
        let headRect = CGRect(x: head.minX, y: head.minY, width: max(2, head.width), height: max(2, head.height))
        color.setFill()
        NSBezierPath(roundedRect: headRect, xRadius: 1, yRadius: 1).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserverToken {
            NotificationCenter.default.removeObserver(windowObserverToken)
            self.windowObserverToken = nil
        }
        if let window = window {
            windowObserverToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.cancelGlide()
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        cancelGlide()
        return super.resignFirstResponder()
    }

    /// Runs the action (letting the real caret land instantly) then glides a
    /// visual ghost from where the caret was to where it now is. Small moves
    /// glide normally; larger gaps glide faster over the distance.
    private func performSmoothAction(_ action: () -> Void) {
        let startRange = selectedRange()
        action()
        let endRange = selectedRange()
        guard startRange != endRange else { return }
        glideCaret(from: startRange.location, to: endRange.location)
    }

    private static let acceleratedKeyCodes: Set<UInt16> = [
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
        selectionBeforeMouseDown = selectedRange()
        pendingClick = (event.locationInWindow, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        super.mouseDown(with: event)
        // The click already moved the REAL caret to the mouse point instantly;
        // glide a visual ghost from wherever the caret was to show it routing.
        // A drag-to-select or double-click forms a selection, so the guard
        // (collapsed caret) cancels the ghost and shows the selection as-is.
        if selectedRange().length == 0 {
            glideCaret(from: selectionBeforeMouseDown.location, to: selectedRange().location)
        }
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
        currentInterval = userBaseInterval()
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
            self.currentInterval = max(self.userMinInterval(), self.currentInterval * 0.92)
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
        
        // Handle delete/backspace with caret glide
        let keyCode = event.keyCode
        if keyCode == 51 || keyCode == 117 { // Backspace or Forward Delete
            let startRange = selectedRange()
            super.keyDown(with: event)
            let endRange = selectedRange()
            if startRange != endRange && startRange.length == 0 && endRange.length == 0 {
                // Caret moved due to deletion, animate it
                glideCaret(from: startRange.location, to: endRange.location)
            }
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

    // MARK: Tab indents list items

    override func insertTab(_ sender: Any?) {
        if !indentCurrentListLine(direction: 1) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !indentCurrentListLine(direction: -1) { super.insertBacktab(sender) }
    }

    /// Moves the caret's list-item line in or out by one indent step for
    /// Tab / Shift-Tab. Returns false when the caret isn't sitting in a
    /// plain list item, so Tab falls back to inserting a tab character.
    private func indentCurrentListLine(direction: Int) -> Bool {
        guard let storage = textStorage,
              !hasMarkedText(),
              selectedRanges.count == 1,
              selectedRange().length == 0 else { return false }
        let selected = selectedRange()
        let line = (storage.string as NSString).lineRange(for: selected)
        guard line.location != NSNotFound, line.length > 0 else { return false }
        let lineText = NSString(string: storage.string).substring(with: line)
        var spaceCount = 0
        var afterSpaces = lineText.startIndex
        while afterSpaces < lineText.endIndex, lineText[afterSpaces] == " " {
            spaceCount += 1
            afterSpaces = lineText.index(after: afterSpaces)
        }
        guard isListMarker(lineText[afterSpaces...]) else { return false }

        let step = 2
        if direction > 0 {
            let spaces = String(repeating: " ", count: step)
            replaceText(in: NSRange(location: line.location, length: 0), with: spaces)
            let newCaret = selected.location == line.location ? line.location : selected.location + step
            setSelectedRange(NSRange(location: newCaret, length: 0))
            return true
        }
        let removed = min(step, spaceCount)
        guard removed > 0 else { return false }
        replaceText(in: NSRange(location: line.location, length: removed), with: "")
        setSelectedRange(NSRange(location: max(line.location, selected.location - removed), length: 0))
        return true
    }

    private func isListMarker(_ rest: Substring) -> Bool {
        guard let first = rest.first else { return false }
        if "-+*".contains(first) { return true }
        var index = rest.startIndex
        while index < rest.endIndex, rest[index].isNumber {
            index = rest.index(after: index)
        }
        return index != rest.startIndex && index < rest.endIndex
            && (rest[index] == "." || rest[index] == ")")
    }

    /// A text change that flows through the editing machinery, so the
    /// delegate (binding sync, re-render, undo) sees it exactly like typing.
    private func replaceText(in range: NSRange, with replacement: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
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

    deinit {
        glideTimer?.invalidate()
        inputSessionTimer?.invalidate()
        if let windowObserverToken {
            NotificationCenter.default.removeObserver(windowObserverToken)
        }
    }
}
