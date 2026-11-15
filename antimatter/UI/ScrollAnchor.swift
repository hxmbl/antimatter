import CoreGraphics

/// Pure viewport maths for re-anchoring the editor after a reflow, kept apart
/// from AppKit so it can be unit tested.
enum ScrollAnchor {
    /// Share of the visible height, measured up from its bottom edge, that
    /// counts as "near the bottom" for keeping the caret in view.
    static let bottomBand: CGFloat = 0.2

    /// True only when the caret is on screen and inside the bottom band.
    ///
    /// A caret below the viewport is *not* near the bottom: the reader has
    /// scrolled away from it, so the reading anchor should win rather than
    /// yanking the view down to the caret.
    static func caretIsNearBottom(caret: CGRect, visible: CGRect) -> Bool {
        guard !caret.isEmpty, visible.height > 0 else { return false }
        guard caret.minY < visible.maxY, caret.maxY > visible.minY else { return false }
        return caret.maxY >= visible.maxY - visible.height * bottomBand
    }

    /// Clamps a desired scroll origin to the document, not the viewport.
    /// Short documents (shorter than the viewport) always sit at the top.
    static func clampedOriginY(target: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let maxY = max(0, documentHeight - viewportHeight)
        guard target.isFinite else { return 0 }
        return min(max(target, 0), maxY)
    }
}
