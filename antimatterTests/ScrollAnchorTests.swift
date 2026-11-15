import CoreGraphics
import Testing
@testable import antimatter

struct ScrollAnchorTests {
    let visible = CGRect(x: 0, y: 1000, width: 400, height: 500)

    @Test func caretInBottomBandIsNearBottom() {
        let caret = CGRect(x: 10, y: 1460, width: 2, height: 22)
        #expect(ScrollAnchor.caretIsNearBottom(caret: caret, visible: visible))
    }

    @Test func caretMidViewportIsNotNearBottom() {
        let caret = CGRect(x: 10, y: 1200, width: 2, height: 22)
        #expect(!ScrollAnchor.caretIsNearBottom(caret: caret, visible: visible))
    }

    @Test func caretBelowViewportIsNotNearBottom() {
        let caret = CGRect(x: 10, y: 2400, width: 2, height: 22)
        #expect(!ScrollAnchor.caretIsNearBottom(caret: caret, visible: visible))
    }

    @Test func caretAboveViewportIsNotNearBottom() {
        let caret = CGRect(x: 10, y: 200, width: 2, height: 22)
        #expect(!ScrollAnchor.caretIsNearBottom(caret: caret, visible: visible))
    }

    @Test func emptyCaretIsNotNearBottom() {
        #expect(!ScrollAnchor.caretIsNearBottom(caret: .zero, visible: visible))
    }

    @Test func clampUsesDocumentHeightNotViewport() {
        // The old clamp used the viewport for both sizes, which pinned any
        // target to 0. A deep anchor in a long document must survive.
        let y = ScrollAnchor.clampedOriginY(target: 10_388, documentHeight: 13_770, viewportHeight: 500)
        #expect(y == 10_388)
    }

    @Test func clampStopsAtDocumentEnd() {
        let y = ScrollAnchor.clampedOriginY(target: 13_600, documentHeight: 13_770, viewportHeight: 500)
        #expect(y == 13_270)
    }

    @Test func clampNeverGoesNegative() {
        #expect(ScrollAnchor.clampedOriginY(target: -40, documentHeight: 13_770, viewportHeight: 500) == 0)
    }

    @Test func shortDocumentSitsAtTop() {
        #expect(ScrollAnchor.clampedOriginY(target: 120, documentHeight: 300, viewportHeight: 500) == 0)
    }
}
