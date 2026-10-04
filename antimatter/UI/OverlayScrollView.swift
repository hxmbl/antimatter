import AppKit

final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        autohidesScrollers = true
        hasHorizontalScroller = false
        drawsBackground = false
        // Deliberately no `scroller.alphaValue = 0` here. With
        // `autohidesScrollers = true` and an overlay scroller AppKit already
        // keeps the scroller hidden while idle; pinning the alpha to 0
        // overrode that and had to be counteracted from `scrollWheel`, which
        // is what left the overlay scroller permanently visible.
    }

    override func tile() {
        super.tile()
        super.scrollerStyle = .overlay
        autohidesScrollers = true
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard PaneStyle.showScrollerWhileScrolling else { return }
        if event.timestamp - lastFlashTimestamp > 0.5 {
            lastFlashTimestamp = event.timestamp
            // `flashScrollers()` shows the scroller and restores the previous
            // alpha itself once the scroll settles. Forcing
            // `verticalScroller?.alphaValue = 1` here was never undone, so the
            // scroller stayed on screen for good after the first scroll.
            flashScrollers()
        }
    }

    private var lastFlashTimestamp: TimeInterval = 0
}