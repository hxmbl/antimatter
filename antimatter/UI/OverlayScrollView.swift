import AppKit

/// Overlay scroller that stays hidden until the user actually scrolls.
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
        verticalScroller?.alphaValue = 0
        horizontalScroller?.alphaValue = 0
    }

    override func tile() {
        super.tile()
        super.scrollerStyle = .overlay
        autohidesScrollers = true
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard PaneStyle.showScrollerWhileScrolling else { return }
        // Restarting the fade on every wheel event keeps the animation
        // permanently churning; only re-flash occasionally.
        if event.timestamp - lastFlashTimestamp > 0.5 {
            lastFlashTimestamp = event.timestamp
            verticalScroller?.alphaValue = 1
            flashScrollers()
        }
    }

    private var lastFlashTimestamp: TimeInterval = 0
}
