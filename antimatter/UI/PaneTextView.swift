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
    // Ported from Zed's `crates/editor/src/cursor_animation.rs`, which credits
    // vscode-neovide-cursor. Three ideas do the work, and each one is here
    // because a simpler version visibly failed:
    //
    // 1. The caret is a *deforming quad*, not a bar. Each of its four corners
    //    is an independent spring with its own duration. Corners that lead the
    //    direction of travel get a much shorter duration than corners trailing
    //    it, so the caret stretches along its path and gathers itself at the
    //    destination. An earlier version drew a second, fading rectangle
    //    behind the caret as a "trail"; because the trail and the caret were
    //    separate shapes, every interrupted hop left one behind, and arrow-key
    //    repeats and clicks accumulated them into stacked ghost cursors. A
    //    stretched quad cannot leave a ghost: there is only ever one shape.
    //
    // 2. State is a displacement from the destination, so retargeting mid-flight
    //    preserves velocity and consecutive hops flow instead of restarting.
    //
    // 3. Springs are solved analytically rather than integrated, so a dropped
    //    frame cannot make the motion ring.

    /// One corner's spring along a single axis, held as a displacement from the
    /// destination. `position` is how far the corner still has to travel;
    /// `velocity` is carried across retargets.
    struct CaretAxis {
        var position: CGFloat = 0
        var velocity: CGFloat = 0

        /// Sub-pixel. Below this the corner is treated as arrived; it is well
        /// under one device pixel on a Retina display, so snapping is invisible.
        static let epsilon: CGFloat = 0.01
        /// While a corner is within this many points of home the quad is treated
        /// as settled for drawing purposes.
        static let restDistance: CGFloat = 0.5

        /// Advances the spring, returning whether it is still moving.
        ///
        /// Critically damped, so it converges without ever overshooting — the
        /// caret cannot bounce past its destination and come back. `length` is
        /// the time the corner should take to arrive, so shorter lengths track
        /// harder and feel snappier.
        mutating func advance(elapsed: CFTimeInterval, length: CFTimeInterval) {
            guard elapsed.isFinite, elapsed > 0, length.isFinite, length > elapsed else {
                position = 0; velocity = 0
                return
            }
            let w = 4.0 / length
            let p0 = position
            let combined = position * w + velocity
            let decay = CGFloat(exp(-w * elapsed))
            position = (p0 + combined * elapsed) * decay
            velocity = decay * (-p0 * w - combined * elapsed * w + combined)

            guard position.isFinite, velocity.isFinite, abs(position) >= Self.epsilon else {
                position = 0; velocity = 0
                return
            }
        }

        mutating func reset() {
            position = 0
            velocity = 0
        }
    }

    /// The caret as four independently sprung corners. Animating the corners
    /// rather than the rectangle is what produces the tapered trail.
    struct CaretQuad {
        /// Corner offsets from the caret's centre, as fractions of its size.
        /// Order is top-left, top-right, bottom-right, bottom-left.
        static let relativePositions: [CGPoint] = [
            CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: -0.5),
            CGPoint(x: 0.5, y: 0.5), CGPoint(x: -0.5, y: 0.5)
        ]

        var current: [CGPoint] = Array(repeating: .zero, count: 4)
        var target: [CGPoint] = Array(repeating: .zero, count: 4)
        var horizontal: [CaretAxis] = Array(repeating: CaretAxis(), count: 4)
        var vertical: [CaretAxis] = Array(repeating: CaretAxis(), count: 4)
        /// Per-corner duration. Leading corners are short, trailing ones long;
        /// that difference is the taper.
        var lengths: [CFTimeInterval] = Array(repeating: Self.defaultLength, count: 4)
        /// Where the caret should end up.
        var targetRect: NSRect = .zero
        /// The character index `targetRect` was measured at. Layout can move the
        /// caret rectangle without the caret moving (a scroll, a reflow), and
        /// that must not be smoothed — only a real index change is a hop.
        var targetIndex: Int = -1
        var isActive = false

        static let defaultLength: CFTimeInterval = 0.125
        static let shortLength: CFTimeInterval = 0.05
        /// Per-corner duration multipliers, trailing first, applied to the base
        /// length. The spread between the fastest and slowest is the taper's
        /// depth.
        ///
        /// Kept deliberately shallow. Zed's leading edge takes 20ms against a
        /// 125ms trailing one, which parks the nose of the caret on the glyph
        /// while the tail is still catching up — so the shape visibly overhung
        /// its character and read as a misaligned caret, and a quick move left a
        /// smear behind it. A narrow ramp keeps the quad arriving together, so
        /// it stays on the character while still reading as motion.
        static let trailFactors: [CGFloat] = [1.0, 0.92, 0.86, 0.8]
        /// A move no wider than this many characters counts as short, which is
        /// what makes typing quick and long jumps leisurely.
        static let shortMoveCharacterWidths: CGFloat = 8

        static func destination(for rect: NSRect, corner index: Int) -> CGPoint {
            let relative = relativePositions[index]
            return CGPoint(x: rect.midX + relative.x * rect.width,
                           y: rect.midY + relative.y * rect.height)
        }

        /// The rectangle spanned by the corners right now. This is what makes
        /// the caret appear to lean into its direction of travel.
        var bounds: NSRect {
            guard !current.isEmpty else { return .zero }
            var minX = current[0].x, maxX = minX
            var minY = current[0].y, maxY = minY
            for point in current.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        mutating func snap(to rect: NSRect, index: Int) {
            targetRect = rect
            targetIndex = index
            for i in 0..<4 {
                let point = Self.destination(for: rect, corner: i)
                current[i] = point
                target[i] = point
                horizontal[i].reset()
                vertical[i].reset()
                lengths[i] = Self.defaultLength
            }
            isActive = false
        }

        /// Points every corner at `rect` and re-seeds each spring's displacement
        /// from where that corner currently *is*, which is what preserves
        /// momentum through an interrupted hop.
        mutating func retarget(to rect: NSRect, index: Int) {
            let previousTarget = targetRect
            targetRect = rect
            targetIndex = index

            // Rank corners by how well their offset points along the direction of
            // travel. The best-aligned corner leads and gets the shortest
            // duration; the worst trails and keeps the longest. That spread is
            // what makes the caret appear to be pulled after its own leading
            // edge.
            let travel = CGPoint(x: rect.midX - previousTarget.midX,
                                 y: rect.midY - previousTarget.midY)
            let travelLength = hypot(travel.x, travel.y)
            // Measured in characters, not points: what matters is how many
            // glyphs the caret crossed, so this scales with the font. A line
            // change is never "short" however few characters it spans, since a
            // vertical hop has further to travel than its width suggests.
            let characterWidth = max(rect.height * 0.5, 1)
            let isLineChange = abs(travel.y) > CaretAxis.restDistance
            let isShortMove = !isLineChange
                && travelLength / characterWidth <= Self.shortMoveCharacterWidths
            let base: CFTimeInterval = isShortMove ? Self.shortLength : Self.defaultLength

            let alignments: [CGFloat] = Self.relativePositions.map { relative in
                let length = hypot(relative.x, relative.y)
                guard travelLength > CaretAxis.epsilon, length > CaretAxis.epsilon else { return -1 }
                return (travel.x / travelLength) * (relative.x / length)
                    + (travel.y / travelLength) * (relative.y / length)
            }
            for (rank, index) in alignments.enumerated().sorted(by: { $0.element < $1.element })
                .map(\.offset).enumerated() {
                // Rank 0 is the least aligned: it trails most and keeps the
                // full base length. The best-aligned corner leads and arrives
                // first, but only slightly — see `trailFactors`.
                lengths[index] = base * CFTimeInterval(Self.trailFactors[min(rank, 3)])
            }

            for i in 0..<4 {
                let destination = Self.destination(for: rect, corner: i)
                target[i] = destination
                horizontal[i].position = destination.x - current[i].x
                vertical[i].position = destination.y - current[i].y
            }
            isActive = true
        }

        /// One frame. Returns whether anything is still moving.
        mutating func advance(elapsed: CFTimeInterval) {
            var moving = false
            for i in 0..<4 {
                let length = lengths[i]
                horizontal[i].advance(elapsed: elapsed, length: length)
                vertical[i].advance(elapsed: elapsed, length: length)
                if abs(horizontal[i].position) > CaretAxis.restDistance
                    || abs(vertical[i].position) > CaretAxis.restDistance {
                    moving = true
                }
                current[i] = CGPoint(x: target[i].x - horizontal[i].position,
                                     y: target[i].y - vertical[i].position)
            }
            isActive = moving
            if !moving { snap(to: targetRect, index: targetIndex) }
        }
    }

    // MARK: Caret testing hooks
    //
    // The caret spring advances from a display link, which a test cannot wait on
    // deterministically. These drive it by hand and expose what the view would
    // otherwise keep to itself.

    var caretQuadForTesting: CaretQuad {
        get { caretQuad ?? CaretQuad() }
        set { caretQuad = newValue }
    }

    /// A bare spring, for checking the integrator on its own.
    func caretAxisForTesting(position: CGFloat, velocity: CGFloat) -> CaretAxis {
        CaretAxis(position: position, velocity: velocity)
    }

    /// Bounds of the quad as currently drawn, resting rectangle included.
    var drawnCaretBoundsForTesting: NSRect {
        let quad = caretQuad
        if quad?.isActive == true { return quad!.bounds }
        return quad?.targetRect ?? caretRestRect ?? .zero
    }

    /// Where the text system itself puts the insertion point at `index`.
    ///
    /// This is the ground truth the caret should be drawn at, derived from the
    /// layout manager's own run measurement rather than from a single glyph's
    /// origin — so it accounts for every advance before the caret, including
    /// kerning and ligature boundaries.
    func insertionPointXForTesting(at index: Int) -> CGFloat? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let length = textStorage?.length ?? 0
        let clamped = min(max(index, 0), length)
        guard clamped > 0 else { return textContainerOrigin.x }

        // Measured from the start of the *line* the caret sits on: a run spanning
        // several lines reports the container width instead, which is not where
        // this caret goes. At a line's first character there is no preceding
        // run on that line, so the line fragment's own origin is the answer.
        let source = textStorage?.string ?? ""
        let ns = source as NSString
        // Probe the caret index itself, not the character before it: probing
        // `clamped - 1` at a line's first character lands on the *previous*
        // line's newline, and the run then measures that whole line.
        let probe = clamped < ns.length ? clamped : max(ns.length - 1, 0)
        let line = ns.lineRange(for: NSRange(location: probe, length: 0))
        let withinLine = clamped - line.location
        guard withinLine > 0 else { return textContainerOrigin.x }

        let characters = NSRange(location: line.location, length: withinLine)
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return textContainerOrigin.x }
        let run = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return textContainerOrigin.x + run.maxX
    }

    /// Where this view currently draws the caret for a character index.
    func caretXForTesting(at index: Int) -> CGFloat? {
        let rect = caretRectForTesting(at: index)
        return rect.isEmpty ? nil : rect.minX
    }

    func caretRectForTesting(at index: Int) -> NSRect {
        caretRect(for: index)
    }

    /// One spring step, bypassing the display link.
    func advanceCaretForTesting(by dt: CFTimeInterval) {
        guard var quad = caretQuad else { return }
        let elapsed = min(max(dt, 0), Self.caretMaxFrame)
        quad.advance(elapsed: elapsed)
        caretQuad = quad
        if !quad.isActive { caretRestRect = quad.targetRect }
    }

    private var caretQuad: CaretQuad?
    private var caretDisplayLink: CADisplayLink?
    /// Frame clock for the spring, kept separate from `CACurrentMediaTime()`
    /// reads so a dropped frame is integrated as a clamped step.
    private var caretLastTick: CFTimeInterval = 0
    /// Where the caret sits once it has come to rest, so the next hop leaves
    /// from where the caret actually appears instead of snapping first.
    private var caretRestRect: NSRect?

    private var caretBlinkTimer: Timer?
    private var caretBlinkOn = true
    private var lastCaretActivity: CFTimeInterval = 0

    private static let caretQuiesceInterval: CFTimeInterval = 0.12
    private var caretQuiesceDeadline: CFTimeInterval = 0

    /// Rounded corners and antialiasing spill just outside the rectangle.
    private static let caretDirtyPadding: CGFloat = 3
    private static let caretBlinkInterval: CFTimeInterval = 0.53
    /// A dropped or blocked frame must not be integrated in one lump, or the
    /// spring visibly jumps. Matches Zed's 33ms clamp.
    private static let caretMaxFrame: CFTimeInterval = 0.033

    private var hasActiveCaret: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self &&
        selectedRange().length == 0 && !hasMarkedText()
    }

    /// The rectangle the caret is painted in right now. While moving this is
    /// the *bounds of the deformed quad*, which is wider than the caret itself
    /// — that is the trail.
    private var drawnCaretRect: NSRect {
        guard let quad = caretQuad, quad.isActive else { return caretRestRect ?? .zero }
        return quad.bounds
    }

    /// Points the caret at wherever the text system actually put the selection,
    /// deforming it into that position rather than teleporting.
    ///
    /// `hasActiveCaret` being false means there is no caret to show (inactive
    /// window, a selection, IME composition), so stop rather than animate
    /// against nothing.
    private func updateCaret() {
        guard hasActiveCaret else {
            stopCaretAnimation()
            return
        }
        noteCaretActivity()

        let index = selectedRange().location
        let target = caretRect(for: index)
        guard !target.isEmpty else { return }
        let previous = drawnCaretRect

        var quad = caretQuad ?? CaretQuad()
        if quad.targetRect.isEmpty {
            // First frame, or arriving from a snapped state: establish the rest
            // position without animating, so there is something to deform from.
            quad.snap(to: target, index: index)
        } else {
            quad.retarget(to: target, index: index)
        }
        caretQuad = quad
        caretRestRect = nil
        caretLastTick = CACurrentMediaTime()
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
        guard hasActiveCaret, var quad = caretQuad else {
            stopCaretAnimation()
            return
        }
        let previous = drawnCaretRect

        // The text system is the source of truth. Re-reading it every frame is
        // what lets a hop that begins before the editor's deferred Markdown
        // render simply follow the text instead of fighting it — and it is why
        // the old generation-tracking and edit-prediction bookkeeping is gone.
        let index = selectedRange().location
        if index != quad.targetIndex {
            let target = caretRect(for: index)
            guard !target.isEmpty else { stopCaretAnimation(); return }
            quad.retarget(to: target, index: index)
        }

        let elapsed = min(max(now - caretLastTick, 0), Self.caretMaxFrame)
        caretLastTick = now
        quad.advance(elapsed: elapsed)
        caretQuad = quad

        let drawn = quad.isActive ? quad.bounds : quad.targetRect
        if !quad.isActive { caretRestRect = quad.targetRect }
        setNeedsDisplay(Self.caretDirty(previous, drawn))

        // Stay subscribed a little past rest: the editor's deferred re-render
        // can still move the caret, and stopping here would make that jump.
        if !quad.isActive, now >= caretQuiesceDeadline { stopCaretLink() }
    }

    private func stopCaretAnimation() {
        let previous = drawnCaretRect
        stopCaretLink()
        caretQuad = nil
        caretRestRect = hasActiveCaret ? caretRect(for: selectedRange().location) : nil
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

    /// Marks the caret as active, which keeps it solid. Blink is suspended
    /// while typing resumes and resumes on its own once typing stops, so the
    /// caret never blinks out from under an active typist.
    private func noteCaretActivity() {
        lastCaretActivity = CACurrentMediaTime()
        let wasOff = !caretBlinkOn
        caretBlinkOn = true
        if wasOff, let rest = caretRestRect {
            setNeedsDisplay(Self.caretDirty(rest, .zero))
        }
        guard caretBlinkTimer == nil, hasActiveCaret else { return }
        caretBlinkTimer = Timer.scheduledTimer(
            withTimeInterval: Self.caretBlinkInterval, repeats: true
        ) { [weak self] _ in
            self?.tickCaretBlink()
        }
    }

    private func tickCaretBlink() {
        // Hold solid until the caret has actually been still for a full
        // interval, so a burst of typing never blinks.
        let idle = CACurrentMediaTime() - lastCaretActivity
        guard idle >= Self.caretBlinkInterval else { return }
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

        // One shape. The four corners are drawn as a single quad, so the
        // taper *is* the trail — there is no second shape that could be left
        // behind as a ghost when a hop is interrupted.
        let quad = caretQuad
        let corners = quad?.isActive == true ? quad!.current : nil
        let rect = quad?.targetRect ?? caretRestRect ?? .zero
        guard !rect.isEmpty else { return }
        guard dirtyRect.intersects(caretBounds(of: corners, restingAt: rect)) else { return }

        // Keep the resting position honest so the next hop deforms from where
        // the caret actually appears.
        if quad?.isActive != true { caretRestRect = rect }

        let path = NSBezierPath()
        if let corners {
            path.move(to: corners[0])
            for point in corners.dropFirst() { path.line(to: point) }
            path.close()
        } else {
            path.appendRoundedRect(rect, xRadius: 1, yRadius: 1)
        }
        // Full opacity: AppKit's caret is not drawn underneath, so the 0.85 the
        // old ghost used would read as permanently faded.
        (insertionPointColor ?? .labelColor).setFill()
        path.fill()
    }

    /// Bounds of the deformed quad, or the resting rectangle.
    private func caretBounds(of corners: [CGPoint]?, restingAt rect: NSRect) -> NSRect {
        guard let corners else { return rect }
        var bounds = NSRect(origin: corners[0], size: .zero)
        for point in corners.dropFirst() { bounds = bounds.union(NSRect(origin: point, size: .zero)) }
        return bounds
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
        // predict which edits move it. Animated like any other hop, but a
        // one-character move is classified as *short* (see `CaretQuad`), which
        // gives it a ~50ms duration — enough to read as motion, little enough
        // that the caret never lags the glyph it belongs to.
        updateCaret()
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
            caretQuad = nil
            return
        }
        caretRestRect = caretRect(for: selectedRange().location)
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
        if selectedRange().length == 0 { updateCaret() } else { stopCaretAnimation() }
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
            if selectedRange().length == 0 { updateCaret() } else { stopCaretAnimation() }
            return
        }

        super.keyDown(with: event)

        // Every key is treated alike. An earlier version gated animation on a
        // hardcoded list of key codes, which meant ⌥-arrow — handled by the text
        // system rather than by `keyDown`'s own arithmetic — fell through
        // unanimated while plain arrows animated. Whether a move is quick or
        // leisurely is now decided by its distance in `CaretQuad`, not by which
        // key produced it.
        if selectedRange().length == 0 {
            updateCaret()
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
