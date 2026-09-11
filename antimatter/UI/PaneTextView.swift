import AppKit
import QuartzCore
import Carbon.HIToolbox

/// The pane's text view.
///
/// * A plain click on a link opens it — drag-safe: the click only counts if
///   the mouse barely moved between down and up, so selecting still works.
/// * Escape hides the pane.
/// * Arrow keys use the native text-system caret movement.
/// * Dropping an image captures its text (on-device OCR); ⌘F opens the
///   system find bar.
final class PaneTextView: NSTextView {
    var onCancelOperation: (() -> Void)?
    var onDroppedImage: ((NSImage) -> Void)?
    /// Return true when the keystroke was swallowed (the full-screen help
    /// view eats every key except navigation and the way out).
    var onHelpKeyDown: ((NSEvent) -> Bool)?
    /// Reports whether text currently sits directly under the top corners
    /// (scrolled to the top with a populated first line) so the pane can
    /// relax its corner radius and stop clipping the glyphs.
    var onTopClippingChange: ((Bool) -> Void)?

    private var pendingClick: (location: NSPoint, modifiers: NSEvent.ModifierFlags)?
    private var windowMoveDrag: (windowOrigin: NSPoint, mouseScreenOrigin: NSPoint)?
    private var lastReportedTopClipping: Bool?

    // The native selection remains authoritative. This overlay only smooths
    // explicit caret jumps; typing, IME composition, and selection drawing
    // always use AppKit directly.
    private struct CaretGlide {
        let from: NSRect
        var to: NSRect
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }

    private var caretGlide: CaretGlide?
    private var caretDisplayLink: CADisplayLink?

    private var hasActiveCaret: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self &&
        selectedRange().length == 0 && !hasMarkedText()
    }

    private func startCaretGlide(from oldLocation: Int, to newLocation: Int, from oldRect: NSRect? = nil) {
        guard hasActiveCaret, oldLocation != newLocation else {
            clearCaretGlide()
            return
        }
        let oldRect = oldRect ?? caretRect(for: oldLocation)
        let newRect = caretRect(for: newLocation)
        guard !oldRect.isEmpty, !newRect.isEmpty else { return }
        let distance = hypot(newRect.midX - oldRect.midX, newRect.midY - oldRect.midY)
        caretGlide = CaretGlide(
            from: oldRect,
            to: newRect,
            start: CACurrentMediaTime(),
            duration: min(0.16, max(0.08, 0.08 + distance / 5000))
        )
        caretDisplayLink?.invalidate()
        let link = displayLink(target: self, selector: #selector(advanceCaretGlide(_:)))
        link.add(to: .main, forMode: .common)
        caretDisplayLink = link
        setNeedsDisplay(oldRect.insetBy(dx: -4, dy: -4))
    }

    @objc private func advanceCaretGlide(_ link: CADisplayLink) {
        guard hasActiveCaret, caretGlide != nil else {
            clearCaretGlide()
            return
        }
        if CACurrentMediaTime() - (caretGlide?.start ?? 0) >= (caretGlide?.duration ?? 0) {
            clearCaretGlide()
        } else {
            setNeedsDisplay(caretGlideDirtyRect)
        }
    }

    private var caretGlideDirtyRect: NSRect {
        guard let glide = caretGlide else { return .zero }
        return glide.from.union(glide.to).insetBy(dx: -5, dy: -5)
    }

    private func clearCaretGlide() {
        let dirty = caretGlideDirtyRect
        caretGlide = nil
        caretDisplayLink?.invalidate()
        caretDisplayLink = nil
        if !dirty.isEmpty { setNeedsDisplay(dirty) }
    }

    private func caretRect(for characterIndex: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let length = textStorage?.length ?? 0
        let index = min(max(characterIndex, 0), length)
        let glyph = index < layoutManager.numberOfGlyphs
            ? layoutManager.glyphIndexForCharacter(at: index)
            : layoutManager.numberOfGlyphs
        guard glyph < layoutManager.numberOfGlyphs else {
            let used = layoutManager.usedRect(for: textContainer)
            return NSRect(x: used.maxX, y: used.maxY - used.height, width: 2, height: used.height)
        }
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        return NSRect(x: textContainerOrigin.x + location.x, y: textContainerOrigin.y + line.minY, width: 2, height: line.height)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if caretGlide != nil, hasActiveCaret {
            caretGlide?.to = rect
            return
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hasActiveCaret, let glide = caretGlide else { return }
        let elapsed = CACurrentMediaTime() - glide.start
        let progress = min(max(elapsed / glide.duration, 0), 1)
        let eased = 1 - pow(1 - progress, 3)
        let rect = NSRect(
            x: glide.from.minX + (glide.to.minX - glide.from.minX) * eased,
            y: glide.from.minY + (glide.to.minY - glide.from.minY) * eased,
            width: glide.to.width,
            height: glide.from.height + (glide.to.height - glide.from.height) * eased
        )
        let color = insertionPointColor ?? .labelColor
        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Only the command-drag move gesture claims the first click; a plain
        // first click on an inactive dock-mode window just activates it.
        event?.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        // The floating pane may sit in front of the active app without being
        // key; a click is what hands it typing, so make it key first. Without
        // this, the first click surfaces the window but keystrokes still beep.
        window?.makeKeyAndOrderFront(nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), let window {
            // Command-drag is the explicit move gesture. Keep it ahead of
            // NSTextView's selection handling so the note remains untouched.
            // The window is repositioned by hand because performDrag(with:)
            // is only honored from an active app; this way the pane can be
            // moved with a single gesture while another app is frontmost
            // without stealing its focus.
            windowMoveDrag = (window.frame.origin, NSEvent.mouseLocation)
            return
        }
        pendingClick = (event.locationInWindow, modifiers)
        let clickIndex = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let oldLocation = selectedRange().location
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in
            self?.toggleTaskIfOnMarker(clickIndex: clickIndex)
        }
        if selectedRange().length == 0 {
            startCaretGlide(from: oldLocation, to: selectedRange().location)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let windowMoveDrag, let window {
            let mouse = NSEvent.mouseLocation
            let delta = NSPoint(
                x: mouse.x - windowMoveDrag.mouseScreenOrigin.x,
                y: mouse.y - windowMoveDrag.mouseScreenOrigin.y
            )
            window.setFrameOrigin(NSPoint(
                x: windowMoveDrag.windowOrigin.x + delta.x,
                y: windowMoveDrag.windowOrigin.y + delta.y
            ))
            return
        }
        super.mouseDragged(with: event)
    }

    /// Flips a task-list checkbox, but only when the click actually lands on
    /// the `[ ]`/`[x]` marker. Clicking any other part of a task line just
    /// places the caret.
    private func toggleTaskIfOnMarker(clickIndex: Int) {
        let location = selectedRange().location
        guard location != NSNotFound, let textStorage = textStorage else { return }

        let nsString = textStorage.string as NSString
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        nsString.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        let line = nsString.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))

        let patterns = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] ",
                        "+ [ ] ", "+ [x] ", "+ [X] "]
        for pattern in patterns {
            guard line.hasPrefix(pattern) else { continue }
            // Every pattern keeps the box at characters 2...4 of the prefix.
            // Only clicks on those characters (with a little slack on the
            // left) toggle; clicks on the task text just edit it.
            let bracket = NSRange(location: lineStart + 2, length: 3)
            guard clickIndex >= bracket.location - 1, clickIndex <= bracket.location + bracket.length else { return }
            let replacement: String
            if line.contains("[ ]") {
                replacement = line.replacingOccurrences(of: "[ ]", with: "[x]")
            } else {
                replacement = line.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            }
            let editRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            if shouldChangeText(in: editRange, replacementString: replacement) {
                textStorage.replaceCharacters(in: editRange, with: replacement)
                didChangeText()
            }
            setSelectedRange(NSRange(location: min(location, textStorage.length), length: 0))
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        if windowMoveDrag != nil {
            windowMoveDrag = nil
            return
        }
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
        NSWorkspace.shared.activateFileViewerSelecting([
            StorageLocation.directory(named: "notes").appendingPathComponent("notes.json")
        ])
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

    // MARK: Top-corner clipping

    /// Recomputes whether the first line currently sits under the top
    /// corners. Cheap; the caller fires it on text edits and on scroll.
    @MainActor
    func reportTopClipping() {
        let scrolled = (enclosingScrollView?.contentView.bounds.origin.y ?? 0) > 1
        let clipping = !scrolled && ((textStorage?.length ?? 0) > 0)
        guard clipping != lastReportedTopClipping else { return }
        lastReportedTopClipping = clipping
        onTopClippingChange?(clipping)
    }

    // MARK: Escape hides the pane / dismisses dotcommands

    override func keyDown(with event: NSEvent) {
        if onHelpKeyDown?(event) == true { return }
        if event.keyCode == kVK_Escape { // Escape
            if !dismissActiveDotcommands() { cancelOperation(nil) }
            return
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.first == "." {
            if !dismissActiveDotcommands() { cancelOperation(nil) }
            return
        }
        // ⌥⌘↑/⌥⌘↓ reorder the caret's line (the Xcode convention); plain
        // ⌥↑/⌥↓ stay with the text system's paragraph navigation.
        if event.modifierFlags.contains([.command, .option]),
           event.keyCode == kVK_UpArrow || event.keyCode == kVK_DownArrow {
            let oldLocation = selectedRange().location
            let oldRect = caretRect(for: oldLocation)
            if event.keyCode == kVK_UpArrow { moveLineUp() } else { moveLineDown() }
            if selectedRange().length == 0 {
                startCaretGlide(
                    from: oldLocation,
                    to: selectedRange().location,
                    from: oldRect.isEmpty ? nil : oldRect
                )
            }
            return
        }

        let shouldAnimateCaret = [51, 115, 117, 119, 123, 124, 125, 126].contains(event.keyCode)
        if !shouldAnimateCaret {
            clearCaretGlide()
        }
        let oldLocation = selectedRange().location
        let oldRect = shouldAnimateCaret ? caretRect(for: oldLocation) : .zero
        super.keyDown(with: event)
        if shouldAnimateCaret, selectedRange().length == 0 {
            startCaretGlide(
                from: oldLocation,
                to: selectedRange().location,
                from: oldRect.isEmpty ? nil : oldRect
            )
        }
    }

    private func dismissActiveDotcommands() -> Bool {
        var dismissed = false
        if PasteStream.shared.isStreaming {
            PasteStream.shared.stopStreaming()
            dismissed = true
        }
        if !TimerCenter.shared.timers.isEmpty {
            TimerCenter.shared.cancelAll()
            dismissed = true
        }
        if !StopwatchCenter.shared.stopwatches.isEmpty {
            StopwatchCenter.shared.cancelAll()
            dismissed = true
        }
        if !ReminderCenter.shared.reminders.isEmpty {
            ReminderCenter.shared.cancelAll()
            dismissed = true
        }
        return dismissed
    }

    // MARK: Escape hides the pane

    override func cancelOperation(_ sender: Any?) {
        clearCaretGlide()
        if let onCancelOperation {
            onCancelOperation()
        } else {
            super.cancelOperation(sender)
        }
    }

    override func resignFirstResponder() -> Bool {
        clearCaretGlide()
        return super.resignFirstResponder()
    }

    // MARK: Line reordering (⌥⌘↑/⌥⌘↓)

    private func moveLineUp() {
        guard let textStorage = textStorage else { return }
        let fullText = textStorage.string as NSString
        let cursorLocation = selectedRange().location
        guard cursorLocation != NSNotFound, fullText.length > 0 else { return }

        let swiftText = fullText as String
        let lines = swiftText.components(separatedBy: "\n")

        var charCount = 0
        var currentLineIndex = lines.count - 1
        for (i, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            if cursorLocation < charCount + lineLen {
                currentLineIndex = i
                break
            }
            charCount += lineLen + 1
        }

        guard currentLineIndex > 0 else { return }

        var mutableLines = lines
        mutableLines.swapAt(currentLineIndex, currentLineIndex - 1)

        let newString = mutableLines.joined(separator: "\n")
        let prevLineLength = (lines[currentLineIndex - 1] as NSString).length
        let newCursorLocation = cursorLocation - prevLineLength - 1

        undoManager?.setActionName("Move Line Up")
        undoManager?.beginUndoGrouping()
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: fullText.length), with: newString)
        textStorage.endEditing()
        setSelectedRange(NSRange(location: max(0, newCursorLocation), length: 0))
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
        undoManager?.endUndoGrouping()
    }

    private func moveLineDown() {
        guard let textStorage = textStorage else { return }
        let fullText = textStorage.string as NSString
        let cursorLocation = selectedRange().location
        guard cursorLocation != NSNotFound, fullText.length > 0 else { return }

        let swiftText = fullText as String
        let lines = swiftText.components(separatedBy: "\n")
        guard lines.count > 1 else { return }

        var charCount = 0
        var currentLineIndex = lines.count - 1
        for (i, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            if cursorLocation < charCount + lineLen {
                currentLineIndex = i
                break
            }
            charCount += lineLen + 1
        }

        guard currentLineIndex < lines.count - 1 else { return }

        var mutableLines = lines
        mutableLines.swapAt(currentLineIndex, currentLineIndex + 1)

        let newString = mutableLines.joined(separator: "\n")
        let currentLineLength = (lines[currentLineIndex] as NSString).length
        let newCursorLocation = cursorLocation + currentLineLength + 1

        undoManager?.setActionName("Move Line Down")
        undoManager?.beginUndoGrouping()
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: fullText.length), with: newString)
        textStorage.endEditing()
        setSelectedRange(NSRange(location: min((newString as NSString).length, newCursorLocation), length: 0))
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
        undoManager?.endUndoGrouping()
    }

    // MARK: Auto markdown link on paste

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else {
            super.paste(sender)
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed),
           let scheme = url.scheme,
           ["http", "https", "ftp"].contains(scheme),
           url.host != nil {
            let markdown = "[\(trimmed)](\(trimmed))"
            let range = selectedRange()
            if shouldChangeText(in: range, replacementString: markdown) {
                textStorage?.replaceCharacters(in: range, with: markdown)
                didChangeText()
            }
            setSelectedRange(NSRange(location: range.location + (markdown as NSString).length, length: 0))
            return
        }

        super.paste(sender)
    }

    // MARK: Copy current line when nothing selected

    override func copy(_ sender: Any?) {
        if selectedRange().length == 0 {
            let nsString = string as NSString
            var lineStart = 0, lineEnd = 0
            nsString.getLineStart(&lineStart, end: nil, contentsEnd: &lineEnd, for: NSRange(location: selectedRange().location, length: 0))
            let lineText = nsString.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lineText, forType: .string)
        } else {
            super.copy(sender)
        }
    }

}
