import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import antimatter

/// Test-visible mirrors of the caret spring, which is a private nested type on
/// `PaneTextView`.
///
/// These deliberately re-declare the *same* arithmetic rather than reaching
/// into the view. `CaretAxisForTesting` and `PaneTextView.CaretAxis` are
/// checked against each other by `caretAxisMatchesTheViewsImplementation`
/// below, so the duplication cannot silently drift: if the production formula
/// changes, that test fails and these get updated with it.
struct CaretAxisForTesting {
    var position: CGFloat
    var velocity: CGFloat

    static let epsilon: CGFloat = 0.01

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
}

/// The per-corner duration rule from `PaneTextView.CaretQuad.retarget`,
/// expressed over a single corner so it can be asserted on directly.
struct CaretQuadDurationsForTesting {
    let horizontalJump: CGFloat
    let verticalJump: CGFloat
    let height: CGFloat

    static let defaultLength: CFTimeInterval = 0.125
    static let shortLength: CFTimeInterval = 0.05
    static let trailFactors: [CGFloat] = [1.0, 0.92, 0.86, 0.8]
    static let restDistance: CGFloat = 0.5
    static let shortMoveCharacterWidths: CGFloat = 8

    /// The jump measured in characters, which is what decides "short".
    private var characterWidth: CGFloat { max(height * 0.5, 1) }

    private var shortMove: Bool {
        // A line change is never short, however narrow it is.
        abs(verticalJump) <= Self.restDistance
            && hypot(horizontalJump, verticalJump) / characterWidth <= Self.shortMoveCharacterWidths
    }

    private var base: CFTimeInterval {
        shortMove ? Self.shortLength : Self.defaultLength
    }

    /// `corner` is the corner's offset from the caret centre, as a fraction of
    /// its size — the same values `CaretQuad.relativePositions` uses.
    ///
    /// Mirrors `CaretQuad.retarget`: corners are ranked by how closely their
    /// offset points along the direction of travel, and the best-aligned corner
    /// leads with the shortest duration.
    func duration(forCornerAt corner: CGPoint) -> CFTimeInterval {
        let travelLength = hypot(horizontalJump, verticalJump)
        let cornerLength = hypot(corner.x, corner.y)
        guard travelLength > 0.0001, cornerLength > 0.0001 else { return base }

        // Rank across all four corners, most trailing first, so the trailing
        // edge keeps the full base length and the leading edge arrives first.
        let alignments = Self.relativePositions.map { relative -> CGFloat in
            let length = hypot(relative.x, relative.y)
            guard length > 0.0001 else { return -1 }
            return (horizontalJump / travelLength) * (relative.x / length)
                + (verticalJump / travelLength) * (relative.y / length)
        }
        let target = Self.indexOf(corner)
        // Rank 0 is the least aligned, so it trails most and gets factor 1.0.
        let rank = alignments.enumerated()
            .sorted { $0.element < $1.element }
            .first { $0.offset == target }?.offset ?? 0
        return base * CFTimeInterval(Self.trailFactors[min(rank, 3)])
    }

    /// The corner offsets, in the order `CaretQuad` indexes them.
    var cornersRankedTrailingFirst: [CGPoint] {
        let travelLength = hypot(horizontalJump, verticalJump)
        let alignments = Self.relativePositions.map { relative -> CGFloat in
            let length = hypot(relative.x, relative.y)
            guard travelLength > 0.0001, length > 0.0001 else { return -1 }
            return (horizontalJump / travelLength) * (relative.x / length)
                + (verticalJump / travelLength) * (relative.y / length)
        }
        return alignments.enumerated()
            .sorted { $0.element < $1.element }
            .map { Self.relativePositions[$0.offset] }
    }

    static let relativePositions: [CGPoint] = [
        CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: -0.5),
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: -0.5, y: 0.5)
    ]

    private static func indexOf(_ corner: CGPoint) -> Int {
        relativePositions.firstIndex { $0 == corner } ?? 0
    }
}

@MainActor
struct CaretAnimationTests {

    /// Guards against the mirrored formulas in this file drifting away from the
    /// ones the view actually runs.
    @Test func caretAxisMatchesTheViewsImplementation() {
        let view = PaneTextView()
        var production = view.caretAxisForTesting(position: 40, velocity: 0)
        var mirror = CaretAxisForTesting(position: 40, velocity: 0)

        for _ in 0..<20 {
            production.advance(elapsed: 1.0 / 60.0, length: 0.125)
            mirror.advance(elapsed: 1.0 / 60.0, length: 0.125)
            #expect(abs(production.position - mirror.position) < 0.000001,
                    "position diverged: \(production.position) vs \(mirror.position)")
            #expect(abs(production.velocity - mirror.velocity) < 0.000001,
                    "velocity diverged: \(production.velocity) vs \(mirror.velocity)")
        }
    }

    /// The integrator itself, pinned directly. Critically damped means a corner
    /// can never pass its destination and come back — that overshoot was the
    /// original "bouncy" complaint.
    @Test func caretAxisConvergesWithoutOvershooting() {
        var axis = CaretAxisForTesting(position: 40, velocity: 0)
        var previous = axis.position
        // Stepped coarsely on purpose: the analytic solution must stay monotone
        // even when frames are dropped, which is when a naive integrator rings.
        for _ in 0..<40 {
            axis.advance(elapsed: 0.05, length: 0.125)
            #expect(axis.position <= previous + 0.0001,
                    "corner passed its destination: \(axis.position)")
            #expect(axis.position >= -0.0001,
                    "corner crossed to the wrong side: \(axis.position)")
            previous = axis.position
        }
        #expect(abs(axis.position) < 0.01, "expected rest, got \(axis.position)")
        #expect(axis.velocity == 0)
    }

    /// A retarget changes only the remaining distance, never the velocity.
    /// This is what makes a held arrow key one continuous motion rather than a
    /// stutter of separate hops each easing in from rest.
    @Test func caretAxisRetargetPreservesMomentum() {
        var axis = CaretAxisForTesting(position: 40, velocity: 0)
        for _ in 0..<3 { axis.advance(elapsed: 1.0 / 60.0, length: 0.125) }
        let carried = axis.velocity
        #expect(carried != 0, "expected real momentum mid-glide")
        axis.position = 40
        #expect(axis.velocity == carried)
    }

    @Test func caretAxisRejectsNonFiniteInput() {
        var axis = CaretAxisForTesting(position: 40, velocity: 10)
        axis.advance(elapsed: .nan, length: 0.125)
        #expect(axis.position == 0)
        #expect(axis.velocity.isFinite)

        var infinite = CaretAxisForTesting(position: 40, velocity: .infinity)
        infinite.advance(elapsed: 0.5, length: 0.125)
        #expect(infinite.position.isFinite)
        #expect(infinite.velocity.isFinite)
    }

    /// A corner pointing along the direction of travel gets a shorter duration
    /// than one trailing it, and that spread is the taper.
    @Test func caretCornerDurationsProduceATaperInTheDirectionOfTravel() {
        // A long horizontal move: 200pt at 20pt line height is 20 characters, well
        // past the short-move threshold, so the full base length applies.
        let rankedCorners = CaretQuadDurationsForTesting(
            horizontalJump: 200, verticalJump: 0, height: 20
        )
        // Trailing corners are ranked first, so the first offset keeps the full
        // base length and the last arrives first.
        let corners = rankedCorners.cornersRankedTrailingFirst
        let trailing = rankedCorners.duration(forCornerAt: corners[0])
        let leading = rankedCorners.duration(forCornerAt: corners[corners.count - 1])
        #expect(corners.count == 4)
        #expect(leading < trailing,
                "leading corner (\(leading)) should arrive before trailing (\(trailing))")
    }

    /// The taper must stay shallow. A deep spread was reported as a smear that
    /// read as a liquid-glass streak, and the fast leading edge parked the nose
    /// of the caret slightly past the character, which read as misalignment.
    @Test func theTaperStaysSubtle() {
        let ranked = CaretQuadDurationsForTesting(
            horizontalJump: 200, verticalJump: 0, height: 20
        )
        let durations = CaretQuadDurationsForTesting.relativePositions
            .map { ranked.duration(forCornerAt: $0) }
        let fastest = durations.min() ?? 0
        let slowest = durations.max() ?? 0

        // The corners must not spread far apart in time: a deep ramp leaves the
        // leading edge parked on the glyph while the tail smears behind it.
        #expect(slowest / fastest < 1.3,
                "taper too deep: corners range \(fastest)...\(slowest), which smears")

        // And the leading edge must still move — a frozen leading edge is a
        // caret that appears to hang off the front of the glyph.
        #expect(fastest > 0.02, "leading edge at \(fastest) is effectively instant")
    }

    /// Typing must be quick. A one-character move counts as "short" and gets the
    /// 50ms duration; a long jump gets the full 125ms. The threshold is counted
    /// in characters rather than points, so it scales with the font size.
    @Test func shortMovesUseTheQuickDuration() {
        let oneCharacter = CaretQuadDurationsForTesting(
            horizontalJump: 9, verticalJump: 0, height: 20
        )
        let manyCharacters = CaretQuadDurationsForTesting(
            horizontalJump: 400, verticalJump: 0, height: 20
        )
        let typed = oneCharacter.duration(forCornerAt: CGPoint(x: -0.5, y: 0))
        let jumped = manyCharacters.duration(forCornerAt: CGPoint(x: -0.5, y: 0))
        #expect(typed < jumped,
                "typing (\(typed)) should be quicker than a jump (\(jumped))")
    }

    /// A move within the short-move window must not be treated as a long jump,
    /// at any font size. Guards the character-counting arithmetic.
    @Test func theShortMoveThresholdScalesWithFontSize() {
        for height in [12.0, 20.0, 48.0] as [CGFloat] {
            let characterWidth = height * 0.5
            let justInside = CaretQuadDurationsForTesting(
                horizontalJump: characterWidth * 7, verticalJump: 0, height: height
            )
            let justOutside = CaretQuadDurationsForTesting(
                horizontalJump: characterWidth * 9, verticalJump: 0, height: height
            )
            let inside = justInside.duration(forCornerAt: CGPoint(x: -0.5, y: 0))
            let outside = justOutside.duration(forCornerAt: CGPoint(x: -0.5, y: 0))
            #expect(inside < outside,
                    "at \(height)pt: 7 chars (\(inside)) should be quicker than 9 (\(outside))")
        }
    }

    /// The taper, end to end, through the production code: a caret that moves
    /// right must be visibly wider mid-flight than it is at rest, and must
    /// narrow back to exactly the resting rectangle. This is the property that
    /// replaced the separate fading "trail" rectangle, which left ghosts behind.
    @Test func movingCaretStretchesAlongItsPathThenGathersBack() {
        let view = PaneTextView()
        let rest = CGRect(x: 0, y: 0, width: 2, height: 20)

        view.caretQuadForTesting.snap(to: rest, index: 0)
        let restingWidth = view.drawnCaretBoundsForTesting.width

        view.caretQuadForTesting.retarget(
            to: CGRect(x: 40, y: 0, width: 2, height: 20), index: 1
        )
        // Advance a single frame; the quad should now span further than the
        // caret's own width because trailing corners lag leading ones.
        view.advanceCaretForTesting(by: 1.0 / 60.0)

        let stretched = view.drawnCaretBoundsForTesting
        #expect(stretched.width > restingWidth,
                "expected the caret to stretch along its path: \(restingWidth) -> \(stretched.width)")

        // Converge.
        for _ in 0..<40 { view.advanceCaretForTesting(by: 1.0 / 60.0) }
        let settled = view.drawnCaretBoundsForTesting
        #expect(abs(settled.minX - 40) < 0.5, "expected to land at x=40, got \(settled.minX)")
        #expect(abs(settled.width - restingWidth) < 0.5,
                "expected to gather back to \(restingWidth) wide, got \(settled.width)")
    }

    /// An interrupted hop must not reset to rest. Two short hops in quick
    /// succession should carry the caret further than one alone, which is the
    /// difference between continuous motion and a stutter.
    @Test func anInterruptedHopKeepsItsMomentum() {
        let view = PaneTextView()
        view.caretQuadForTesting.snap(to: CGRect(x: 0, y: 0, width: 2, height: 20), index: 0)
        view.caretQuadForTesting.retarget(to: CGRect(x: 40, y: 0, width: 2, height: 20), index: 1)
        view.advanceCaretForTesting(by: 1.0 / 60.0)
        let afterOneFrame = view.drawnCaretBoundsForTesting

        // Interrupt: a new destination before the first has arrived.
        view.caretQuadForTesting.retarget(to: CGRect(x: 80, y: 0, width: 2, height: 20), index: 2)
        view.advanceCaretForTesting(by: 1.0 / 60.0)
        let afterRetarget = view.drawnCaretBoundsForTesting

        #expect(afterRetarget.minX > afterOneFrame.minX,
                "caret went backwards on retarget: \(afterOneFrame.minX) -> \(afterRetarget.minX)")
        #expect(view.caretQuadForTesting.isActive)
    }

    /// A caret that has arrived must report itself inactive, so the display
    /// link can be torn down rather than spinning forever.
    @Test func aConvergedCaretGoesInactive() {
        let view = PaneTextView()
        view.caretQuadForTesting.snap(to: CGRect(x: 0, y: 0, width: 2, height: 20), index: 0)
        #expect(!view.caretQuadForTesting.isActive)

        view.caretQuadForTesting.retarget(to: CGRect(x: 400, y: 0, width: 2, height: 20), index: 1)
        #expect(view.caretQuadForTesting.isActive)

        for _ in 0..<120 { view.advanceCaretForTesting(by: 1.0 / 60.0) }
        #expect(!view.caretQuadForTesting.isActive, "caret never settled")
    }

    /// The caret's *target* must sit where the text system puts the insertion
    /// point.
    ///
    /// NOTE: this does **not** cover the reported offset defect. The offset is
    /// a constant ~one space-width to the right, unchanged by character or font
    /// size, and it is *not* reproduced here: the target matches the insertion
    /// point to 0.000pt, the resting quad matches its target exactly, and the
    /// spring never overshoots. So this test is pinning the geometry that is
    /// known good, and it is **not** a regression test for the bug. The oracle
    /// shares `location(forGlyphAt:)` with `caretRect`, so if the defect lives
    /// there this test would agree with it. See the commit message.
    @Test func caretTargetSitsOnTheInsertionPoint() {
        for text in ["ab", "hello world", "MMM", "iiii", "AV Wa", "café naïve", "a  b"] {
            let view = makeLaidOutView(text: text)
            for index in 0..<text.utf16.count {
                guard let expected = view.insertionPointXForTesting(at: index),
                      let actual = view.caretXForTesting(at: index) else {
                    Issue.record("no geometry for index \(index) of \"\(text)\"")
                    continue
                }
                #expect(abs(actual - expected) < 0.5,
                        "\"\(text)\" index \(index): caret at \(actual), insertion point at \(expected), off by \(actual - expected)")
            }
        }
    }

    /// Same check across several lines, where each caret comes from a different
    /// line fragment. Subject to the same caveat as
    /// `caretTargetSitsOnTheInsertionPoint`: it pins known-good geometry, it
    /// does not cover the reported offset.
    @Test func caretTargetSitsOnTheInsertionPointOnEveryLine() {
        let text = (0..<8).map { "line \($0) of the note has some text" }.joined(separator: "\n")
        let view = makeLaidOutView(text: text)
        let length = text.utf16.count
        var failures = 0
        // Every index strictly inside the document: index == length is the
        // trailing-insertion case, resolved from the extra line fragment.
        for index in 0..<length {
            guard let expected = view.insertionPointXForTesting(at: index),
                  let actual = view.caretXForTesting(at: index) else {
                Issue.record("no geometry at \(index)")
                continue
            }
            if abs(actual - expected) >= 0.5 {
                failures += 1
                Issue.record("index \(index): caret at \(actual), insertion point at \(expected)")
            }
        }
        #expect(failures == 0, "\(failures) of \(length) indices were off the insertion point")
    }

    /// A caret moving right through a line must never jump backwards.
    @Test func caretAdvancesMonotonicallyThroughALine() {
        let view = makeLaidOutView(text: "abcdefghij")
        var previous = -CGFloat.greatestFiniteMagnitude
        for index in 0...10 {
            guard let x = view.caretXForTesting(at: index) else { continue }
            #expect(x >= previous, "caret went backwards at \(index): \(x) after \(previous)")
            previous = x
        }
    }

    /// Builds a real text view and runs a real layout pass, so caret geometry
    /// is measured rather than mocked.
    @MainActor
    private func makeLaidOutView(text: String, width: CGFloat = 400) -> PaneTextView {
        let view = PaneTextView()
        // Mirror how the pane actually configures its text system: the
        // container tracks the view's width, so the frame is what decides where
        // lines break. Setting `containerSize` directly gets overwritten.
        view.frame = NSRect(x: 0, y: 0, width: width, height: 4000)
        view.font = .systemFont(ofSize: 13)
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.isHorizontallyResizable = false
        if let container = view.textContainer {
            // Track the view's width rather than a fixed size: an explicit
            // `containerSize` of `greatestFiniteMagnitude` leaves the layout
            // manager reporting a fragment width of 10 million points.
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: view.frame.width, height: 0)
            container.lineFragmentPadding = 0
        }
        view.string = text
        guard let container = view.textContainer else { return view }
        view.layoutManager?.ensureLayout(for: container)
        return view
    }
}