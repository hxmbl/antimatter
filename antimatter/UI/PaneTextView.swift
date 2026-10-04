import AppKit
import QuartzCore
import Carbon.HIToolbox

final class PaneTextView: NSTextView {
    var onCancelOperation: (() -> Void)?
    var onDroppedImage: ((NSImage) -> Void)?
    var onHelpKeyDown: ((NSEvent) -> Bool)?
    var onTabKeyDown: (() -> Bool)?
    var onTopTextLevelChange: ((CGFloat) -> Void)?

    /// True while the pane is showing a read-only block (`.help`, `.timer list`,
    /// `.stats`, …) rather than the note.
    ///
    /// `isEditable = false` covers typing and ⌘V, but it does **not** cover a
    /// drop: `performDragOperation` here routes images straight to
    /// `onDroppedImage`, and a dropped text file reaches
    /// `super.performDragOperation` → `readSelection(from:)` → `insertText`,
    /// which fires `textDidChange` and writes the result into `NoteStore`. Since
    /// `ReferenceViewManager.exit` restores the stashed note with `.string =`
    /// (which does *not* post `textDidChange`), the stash cannot undo it — so
    /// dropping a file while reading `.help` destroyed the note. Drag and drop
    /// is not routed through `doCommandBy`, so nothing else gated it.
    var isReferenceMode = false

    private var pendingClick: (location: NSPoint, modifiers: NSEvent.ModifierFlags)?
    private var windowMoveDrag: (windowOrigin: NSPoint, mouseScreenOrigin: NSPoint)?
    private var lastReportedTopLevel: CGFloat = -1

    // MARK: Caret
    //
    // The native selection stays authoritative; this only smooths where the
    // caret is *drawn*. One critically damped spring chases the real caret
    // rectangle every frame. The state is a displacement from the current
    // target rather than an absolute position or a fixed-duration tween, and
    // that is what makes consecutive hops flow: moving the target leaves
    // position and velocity untouched, so a keystroke arriving mid-flight
    // continues the motion instead of restarting it from rest. A tween
    // restarts velocity on every hop, which reads as a stutter, and a spring
    // that cannot overshoot cannot bounce.

    /// How the caret should reach a new position.
    private enum CaretMotion {
        /// Snap into place. Teleports and anything not driven by caret
        /// movement; gliding there just looks like a swoop.
        case snap
        /// Stiff spring. The glyph is already on screen, so the caret stays on
        /// it rather than trailing behind what you just typed.
        case typing
        /// Soft spring. Nothing is waiting on the caret, so the extra
        /// smoothness is free.
        case hop

        /// A critically damped spring closes its last pixel in roughly
        /// `4 / frequency`, and that settling time is independent of how far
        /// it has to travel.
        var frequency: CGFloat {
            switch self {
            case .snap: return 0
            case .typing: return 60 // ~65ms
            case .hop: return 30 // ~130ms
            }
        }
    }

    private struct CaretSpring {
        /// Displacement from `target`, in points.
        var offset: CGPoint
        var velocity: CGPoint
        var heightOffset: CGFloat
        var heightVelocity: CGFloat
        var target: NSRect
        /// The character index `target` was measured at. Layout can move the
        /// caret rectangle without the caret moving (scrolling, a reflow), and
        /// that must not be smoothed — only an actual index change is a hop.
        var targetIndex: Int
        var lastTick: CFTimeInterval
        var frequency: CGFloat

        /// A quarter point is under one device pixel on a Retina display, so
        /// snapping here is invisible; stopping any sooner would leave the
        /// caret visibly short of the text.
        static let restOffset: CGFloat = 0.25
        static let restVelocity: CGFloat = 1

        var isSettled: Bool {
            abs(offset.x) < Self.restOffset && abs(offset.y) < Self.restOffset
                && abs(heightOffset) < Self.restOffset
                && abs(velocity.x) < Self.restVelocity && abs(velocity.y) < Self.restVelocity
                && abs(heightVelocity) < Self.restVelocity
        }
    }

    private var caretSpring: CaretSpring?
    private var caretDisplayLink: CADisplayLink?
    /// Where the caret sits once it has come to rest, so the next hop leaves
    /// from where the caret actually appears instead of snapping first.
    private var caretRestRect: NSRect?
    private var caretRestIndex: Int?

    private var caretBlinkTimer: Timer?
    private var caretBlinkOn = true

    /// Past this the caret has teleported — a paste, or a click across the
    /// note — rather than stepped.
    private static let maxSmoothedDistance: CGFloat = 400

    /// The editor re-renders Markdown shortly after an edit and the caret can
    /// move again when it lands. Hold the poll open across that window rather
    /// than guessing the final position when the keystroke arrives.
    private static let caretQuiesceInterval: CFTimeInterval = 0.12
    private var caretQuiesceDeadline: CFTimeInterval = 0

    /// Rounded corners and antialiasing spill just outside the rectangle.
    private static let caretDirtyPadding: CGFloat = 3
    private static let caretBlinkInterval: CFTimeInterval = 0.53

    /// A blocked main thread must not be integrated in one lump, or the spring
    /// would visibly jump instead of easing.
    private static let caretMaxStep: CFTimeInterval = 0.05

    private var hasActiveCaret: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self &&
        selectedRange().length == 0 && !hasMarkedText()
    }

    /// The rectangle the caret is painted in right now.
    private var drawnCaretRect: NSRect {
        guard let spring = caretSpring else { return caretRestRect ?? .zero }
        return NSRect(
            x: spring.target.minX + spring.offset.x,
            y: spring.target.minY + spring.offset.y,
            width: spring.target.width,
            height: max(1, spring.target.height + spring.heightOffset)
        )
    }

    /// One analytic step of a critically damped spring. Solving it exactly
    /// instead of integrating numerically keeps the motion identical at any
    /// frame rate, and critical damping means it cannot overshoot — the caret
    /// settles rather than rings.
    private static func stepSpring(
        offset d0: CGFloat,
        velocity v0: CGFloat,
        dt: CFTimeInterval,
        frequency: CGFloat
    ) -> (offset: CGFloat, velocity: CGFloat) {
        let w = Double(frequency)
        let decay = exp(-w * dt)
        let c = Double(v0) + w * Double(d0)
        return (CGFloat(Double(d0) + c * dt), CGFloat(Double(v0) - w * c * dt))
    }

    /// Points the caret at wherever the text system actually put the
    /// selection. `hasActiveCaret` being false means there is no caret to show
    /// (inactive window, a selection, IME composition), so stop rather than
    /// leave a spring running against nothing.
    private func updateCaret(_ motion: CaretMotion) {
        guard hasActiveCaret else {
            stopCaretAnimation()
            return
        }
        noteCaretActivity()

        let index = selectedRange().location
        let target = caretRect(for: index)
        guard !target.isEmpty else { return }
        let previous = drawnCaretRect
        let travelled = hypot(target.minX - previous.minX, target.minY - previous.minY)

        guard motion.frequency > 0, travelled <= Self.maxSmoothedDistance else {
            stopCaretAnimation()
            caretRestRect = target
            caretRestIndex = index
            setNeedsDisplay(Self.caretDirty(previous, target))
            return
        }

        if var spring = caretSpring {
            spring.target = target
            spring.targetIndex = index
            spring.frequency = motion.frequency
            caretSpring = spring
        } else {
            let from = caretRestRect ?? previous
            caretSpring = CaretSpring(
                offset: CGPoint(x: from.minX - target.minX, y: from.minY - target.minY),
                velocity: .zero,
                heightOffset: from.height - target.height,
                heightVelocity: 0,
                target: target,
                targetIndex: index,
                lastTick: CACurrentMediaTime(),
                frequency: motion.frequency
            )
        }
        keepCaretPolling()
        setNeedsDisplay(Self.caretDirty(previous, drawnCaretRect))
    }

    private func keepCaretPolling() {
        caretQuiesceDeadline = CACurrentMediaTime() + Self.caretQuiesceInterval
        guard caretDisplayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(advanceCaret(_:)))
        link.add(to: .main, forMode: .common)
        caretDisplayLink = link
    }

    @objc private func advanceCaret(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard hasActiveCaret, var spring = caretSpring else {
            stopCaretAnimation()
            return
        }
        let previous = drawnCaretRect

        // The text system is the source of truth. Re-reading it every frame is
        // what lets a hop that begins before the editor's deferred Markdown
        // render simply follow the text instead of fighting it — and it is why
        // the old generation-tracking and edit-prediction bookkeeping is gone.
        let index = selectedRange().location
        if index != spring.targetIndex {
            spring.targetIndex = index
            let target = caretRect(for: index)
            if !target.isEmpty { spring.target = target }
        }

        let dt = min(max(now - spring.lastTick, 0), Self.caretMaxStep)
        spring.lastTick = now
        if dt > 0 {
            let frequency = spring.frequency
            let x = Self.stepSpring(offset: spring.offset.x, velocity: spring.velocity.x, dt: dt, frequency: frequency)
            let y = Self.stepSpring(offset: spring.offset.y, velocity: spring.velocity.y, dt: dt, frequency: frequency)
            let height = Self.stepSpring(offset: spring.heightOffset, velocity: spring.heightVelocity, dt: dt, frequency: frequency)
            spring.offset = CGPoint(x: x.offset, y: y.offset)
            spring.velocity = CGPoint(x: x.velocity, y: y.velocity)
            spring.heightOffset = height.offset
            spring.heightVelocity = height.velocity
        }

        let settled = spring.isSettled
        if settled {
            spring.offset = .zero
            spring.velocity = .zero
            spring.heightOffset = 0
            spring.heightVelocity = 0
        }
        caretSpring = settled ? nil : spring
        if settled {
            caretRestRect = spring.target
            caretRestIndex = spring.targetIndex
        }

        let current = settled ? spring.target : drawnCaretRect
        setNeedsDisplay(Self.caretDirty(previous, current))

        // Stay subscribed a little past rest: an edit's re-render can still
        // move the caret, and stopping here would make that jump instead.
        if settled, now >= caretQuiesceDeadline { stopCaretLink() }
    }

    private func stopCaretAnimation() {
        let previous = drawnCaretRect
        stopCaretLink()
        caretSpring = nil
        caretRestRect = hasActiveCaret ? caretRect(for: selectedRange().location) : nil
        caretRestIndex = hasActiveCaret ? selectedRange().location : nil
        guard let rest = caretRestRect else { return }
        setNeedsDisplay(Self.caretDirty(previous, rest))
    }

    private func stopCaretLink() {
        caretDisplayLink?.invalidate()
        caretDisplayLink = nil
    }

    private static func caretDirty(_ first: NSRect, _ second: NSRect) -> NSRect {
        let rect = first.isEmpty ? second : (second.isEmpty ? first : first.union(second))
        return rect.isEmpty ? .zero : rect.insetBy(dx: -caretDirtyPadding, dy: -caretDirtyPadding)
    }

    /// Restarts the blink phase so the caret stays solid while you type and
    /// only starts blinking once you pause.
    private func noteCaretActivity() {
        caretBlinkOn = true
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        guard hasActiveCaret else { return }
        caretBlinkTimer = Timer.scheduledTimer(
            withTimeInterval: Self.caretBlinkInterval, repeats: true
        ) { [weak self] _ in
            self?.toggleCaretBlink()
        }
        if let rest = caretRestRect { setNeedsDisplay(Self.caretDirty(rest, .zero)) }
    }

    private func toggleCaretBlink() {
        caretBlinkOn.toggle()
        let rect = drawnCaretRect
        guard !rect.isEmpty else { return }
        setNeedsDisplay(Self.caretDirty(rect, .zero))
    }

    private func caretRect(for characterIndex: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let length = textStorage?.length ?? 0
        let index = min(max(characterIndex, 0), length)
        layoutManager.ensureLayout(for: textContainer)

        if index == length {
            // There is no glyph at the insertion point after the final
            // character. Use the extra line fragment for an empty trailing
            // line, otherwise use the last glyph's line fragment. The old
            // fallback used the whole document's usedRect height, which made
            // the caret briefly stretch from the new line to the top/bottom
            // of the note.
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty {
                return NSRect(
                    x: textContainerOrigin.x + extra.minX,
                    y: textContainerOrigin.y + extra.minY,
                    width: 2,
                    height: extra.height
                )
            }
            if layoutManager.numberOfGlyphs > 0 {
                let lastGlyph = layoutManager.numberOfGlyphs - 1
                let line = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                return NSRect(
                    x: textContainerOrigin.x + line.maxX,
                    y: textContainerOrigin.y + line.minY,
                    width: 2,
                    height: line.height
                )
            }
        }

        let glyph = index < layoutManager.numberOfGlyphs
            ? layoutManager.glyphIndexForCharacter(at: index)
            : layoutManager.numberOfGlyphs
        guard glyph < layoutManager.numberOfGlyphs else {
            return .zero
        }
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        return NSRect(x: textContainerOrigin.x + location.x, y: textContainerOrigin.y + line.minY, width: 2, height: line.height)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // The caret is painted in `draw(_:)` instead. Handing it back to AppKit
        // means it reappears on whatever blink phase the text view happens to
        // be in, so the end of a hop could blank the caret for up to half a
        // second — a visible flicker. This used to also overwrite the glide's
        // destination from inside `super.draw(_:)`, which rewrote the animation
        // target frame by frame and made the ghost jitter.
        //
        // `hasActiveCaret` is exactly when AppKit would draw a caret anyway, so
        // IME composition, selections, and inactive windows stay native.
        guard hasActiveCaret else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawVariableGhosts(in: dirtyRect)
        guard hasActiveCaret, caretBlinkOn else { return }
        let rect = drawnCaretRect
        guard !rect.isEmpty, dirtyRect.intersects(rect.insetBy(dx: -1, dy: -1)) else { return }
        // Keep the resting position honest so the next hop leaves from where
        // the caret actually appears.
        if caretSpring == nil {
            caretRestRect = rect
            caretRestIndex = selectedRange().location
        }
        // Full opacity: AppKit's caret is no longer drawn underneath, so the
        // 0.85 the old ghost used would read as permanently faded.
        (insertionPointColor ?? .labelColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    private func drawVariableGhosts(in dirtyRect: NSRect) {
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let source = storage.string
        let variables = VariableTable.scan(source)
        let ns = source as NSString
        for span in ExpressionEvaluator.interpolationSpans(in: source) {
            let lineRange = ns.lineRange(for: span.range)
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(":"), line.contains(" = "),
                  let value = ExpressionEvaluator.evaluateValue(span.inner, variables: variables, buffer: source)
                    ?? IntentExecution.commandDryRun(span.inner, buffer: source).map(SparkValue.number),
                  value.isFinite else { continue }

            var contentEnd = NSMaxRange(lineRange)
            if contentEnd > 0, ns.character(at: contentEnd - 1) == unichar(10) { contentEnd -= 1 }
            let characterRange = NSRange(location: lineRange.location, length: max(0, contentEnd - lineRange.location))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let origin = NSPoint(x: textContainerOrigin.x + lineRect.maxX + 10, y: textContainerOrigin.y + lineRect.minY)
            let ghost = IntentParser.format(value)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: PaneStyle.fontSize - 1, weight: .regular),
                .foregroundColor: PaneStyle.secondaryTextNSColor.withAlphaComponent(0.72)
            ]
            let size = (ghost as NSString).size(withAttributes: attributes)
            let rect = NSRect(origin: origin, size: size)
            guard dirtyRect.intersects(rect) else { continue }
            (ghost as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // Typing and deleting both land here, so the caret does not have to
        // predict which edits move it. `.typing` is stiff on purpose: the
        // character is already drawn, and a soft caret would visibly trail it.
        updateCaret(.typing)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { noteCaretActivity() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        stopCaretAnimation()
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // A live display link retains its target, so leaving the caret
            // running with no window would keep this view alive.
            stopCaretLink()
            caretBlinkTimer?.invalidate()
            caretBlinkTimer = nil
            caretSpring = nil
            return
        }
        caretRestRect = caretRect(for: selectedRange().location)
        caretRestIndex = selectedRange().location
    }

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
        usesFindBar = true
        isIncrementalSearchingEnabled = false
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }


    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event?.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) ?? false
    }

    override func mouseDown(with event: NSEvent) {
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
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in
            self?.toggleTaskIfOnMarker(clickIndex: clickIndex)
        }
        if selectedRange().length == 0 { updateCaret(.hop) } else { stopCaretAnimation() }
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

    /// Flips a task-list checkbox, but only when the click lands on the marker.
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


    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Never accept a drop into a read-only block: it would replace the note
        // behind the reference view. See `isReferenceMode`.
        guard !isReferenceMode else { return [] }
        return containsImage(sender.draggingPasteboard) ? [.copy] : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !isReferenceMode else { return false }
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


    /// Without a menu bar, the pane's right-click menu is the escape hatch.
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


    override func insertTab(_ sender: Any?) {
        if onTabKeyDown?() == true { return }
        if !indentCurrentListLine(direction: 1) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !indentCurrentListLine(direction: -1) { super.insertBacktab(sender) }
    }

    /// Moves the caret's list-item line in or out by one indent step.
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

    /// A text change that flows through the editing machinery like typing.
    private func replaceText(in range: NSRange, with replacement: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }


    /// Recomputes the top-corner relaxation level on text edits and scroll.
    @MainActor
    func reportTopTextLevel() {
        guard let scrollView = enclosingScrollView else { return }
        let offset = scrollView.contentView.bounds.origin.y
        let hasText = ((textStorage?.length ?? 0) > 0)
        let level: CGFloat = hasText
            ? max(0, min(1, 1 - offset / PaneStyle.topClipRelaxBand))
            : 0
        guard abs(level - lastReportedTopLevel) >= 0.02 else { return }
        lastReportedTopLevel = level
        onTopTextLevelChange?(level)
    }


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
        //
        // Parenthesised on purpose: `&&` binds tighter than `||`, so the
        // unparenthesised `A && B || C` parsed as `(A && B) || C` and let a
        // *plain* Down arrow (and ⌘↓, and ⌘↑) fall into the reorder branch —
        // which rewrites the note, registers an undo entry and throws the caret
        // to the end of the document.
        if event.modifierFlags.contains([.command, .option])
            && (event.keyCode == kVK_UpArrow || event.keyCode == kVK_DownArrow) {
            if event.keyCode == kVK_UpArrow { moveLineUp() } else { moveLineDown() }
            if selectedRange().length == 0 { updateCaret(.hop) } else { stopCaretAnimation() }
            return
        }

        let shouldAnimateCaret = [115, 119, 123, 124, 125, 126].contains(event.keyCode)
        super.keyDown(with: event)

        // Typing already moved the caret from `didChangeText`. This covers the
        // keys that only move the selection — the arrows. Everything else
        // (paste, formatting, find, a selection change) snaps: those move the
        // caret somewhere that is not one step away from here.
        if selectedRange().length == 0 {
            updateCaret(shouldAnimateCaret ? .hop : .snap)
        } else {
            stopCaretAnimation()
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


    override func cancelOperation(_ sender: Any?) {
        stopCaretAnimation()
        if let onCancelOperation {
            onCancelOperation()
        } else {
            super.cancelOperation(sender)
        }
    }

    private func lineIndex(of cursorLocation: Int, in lines: [String]) -> Int {
        var charCount = 0
        for (i, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            // `<=`, not `<`: a caret sitting at the very end of a line's content
            // (i.e. immediately before its newline — the position you reach by
            // typing to the end, or pressing ⌘→ / End) belongs to *that* line.
            // With a strict `<` the end-of-line position fell through to the next
            // line, so ⌥⌘↑ from there reordered the line above instead.
            if cursorLocation <= charCount + lineLen { return i }
            charCount += lineLen + 1
        }
        return lines.count - 1
    }

    private func moveLineUp() {
        guard let textStorage = textStorage else { return }
        let fullText = textStorage.string as NSString
        let cursorLocation = selectedRange().location
        guard cursorLocation != NSNotFound, fullText.length > 0 else { return }

        let swiftText = fullText as String
        let lines = swiftText.components(separatedBy: "\n")
        let currentLineIndex = lineIndex(of: cursorLocation, in: lines)

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

        let currentLineIndex = lineIndex(of: cursorLocation, in: lines)
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
