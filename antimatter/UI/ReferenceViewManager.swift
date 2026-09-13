import AppKit
import SwiftUI

/// Manages the full-screen reference view (help / debug). Stashes the note
/// on entry and restores it on exit.
@MainActor
final class ReferenceViewManager {
    private(set) var isInHelpView = false
    private var helpSnapshot: (text: String, selection: NSRange, font: NSFont, isHorizontallyResizable: Bool, widthTracksTextView: Bool, containerSize: NSSize)?
    private weak var helpTextView: NSTextView?

    private let highlighter: MarkdownHighlighter
    private let status: Binding<FooterStatus>
    private let updateFooterStatus: (NSTextView) -> Void

    /// Vim motion state: a pending repeat count and a half-typed `gg`.
    private var pendingCount = 0
    private var pendingIsG = false

    init(highlighter: MarkdownHighlighter, status: Binding<FooterStatus>, updateFooterStatus: @escaping (NSTextView) -> Void) {
        self.highlighter = highlighter
        self.status = status
        self.updateFooterStatus = updateFooterStatus
    }

    /// Enter a full-screen reference block. Stashes the note and editor config.
    func enter(_ textView: NSTextView, content: String) {
        let container = textView.textContainer
        helpSnapshot = (
            textView.string,
            textView.selectedRange(),
            textView.font ?? .systemFont(ofSize: PaneStyle.fontSize),
            textView.isHorizontallyResizable,
            container?.widthTracksTextView ?? false,
            container?.containerSize ?? .zero
        )
        helpTextView = textView
        isInHelpView = true

        // Table-like read-out: monospaced, and each logical line is its
        // own row — never wrapped, so a run-on line can't slip under the
        // following title.
        let mono = NSFont.monospacedSystemFont(ofSize: PaneStyle.fontSize, weight: .regular)
        textView.font = mono
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = content
        textView.textStorage?.setAttributes([
            .font: mono,
            .foregroundColor: PaneStyle.textNSColor,
        ], range: NSRange(location: 0, length: (content as NSString).length))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        textView.window?.makeFirstResponder(textView)
        status.wrappedValue = FooterStatus(preview: "q/Esc close · j/k lines · f/b pages · gg/G top/bottom", answerToCopy: nil)
    }

    /// Restore the stashed note and normal editing.
    func exit() {
        guard isInHelpView,
              let textView = helpTextView,
              let snapshot = helpSnapshot
        else { return }
        isInHelpView = false
        helpSnapshot = nil
        helpTextView = nil
        textView.breakUndoCoalescing()
        textView.string = snapshot.text
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = snapshot.isHorizontallyResizable
        textView.textContainer?.widthTracksTextView = snapshot.widthTracksTextView
        textView.textContainer?.containerSize = snapshot.containerSize
        textView.font = snapshot.font
        highlighter.render(textView)
        textView.setSelectedRange(snapshot.selection)
        textView.window?.makeFirstResponder(textView)
        updateFooterStatus(textView)
    }

    /// Keystroke swallowed by the reference view. Full vim navigation
    /// with repeat-count prefix (e.g. `5j`, `3G`, `2w`), horizontal scroll,
    /// page/half-page jumps, and word motions.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isInHelpView, let textView = helpTextView else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Esc always closes.
        if event.keyCode == 53 {
            resetVim(); exit(); return true
        }

        // Ctrl-d / Ctrl-u / Ctrl-f / Ctrl-b — page motions.
        if flags == [.control] {
            switch event.keyCode {
            case 2:  scrollByFraction(textView, 0.5);  resetVim(); return true  // d
            case 32: scrollByFraction(textView, -0.5); resetVim(); return true  // u
            case 3:  textView.scrollPageDown(nil);      resetVim(); return true  // f
            case 11: textView.scrollPageUp(nil);        resetVim(); return true  // b
            default: break
            }
        }

        // Command / Control + anything else → system navigation passes through.
        if flags.contains(.command) || flags.contains(.control) {
            resetVim(); return false
        }

        guard let characters = event.charactersIgnoringModifiers else { return true }

        // Arrow / Page Up / Page Down / Home / End → native pass-through.
        let navKeyCodes: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        if navKeyCodes.contains(event.keyCode) { resetVim(); return false }

        // Number prefix for repeat counts.
        if let n = Int(characters) {
            if pendingCount == 0 && n == 0 {
                scrollHorizontally(textView, delta: -.infinity)
                resetVim(); return true
            }
            pendingCount = pendingCount * 10 + n
            return true
        }

        let count = pendingCount > 0 ? pendingCount : 1

        switch characters {
        case "q", "Q":
            resetVim(); exit(); return true

        case "j":
            for _ in 0..<count { textView.scrollLineDown(nil) }
            resetVim(); return true
        case "k":
            for _ in 0..<count { textView.scrollLineUp(nil) }
            resetVim(); return true

        case "h":
            scrollHorizontally(textView, delta: -CGFloat(count) * hStep(textView))
            resetVim(); return true
        case "l":
            scrollHorizontally(textView, delta: CGFloat(count) * hStep(textView))
            resetVim(); return true

        case " ", "f":
            textView.scrollPageDown(nil)
            resetVim(); return true
        case "b":
            textView.scrollPageUp(nil)
            resetVim(); return true

        case "w":
            scrollHorizontally(textView, delta: CGFloat(count) * wStep(textView))
            resetVim(); return true
        case "e":
            scrollHorizontally(textView, delta: CGFloat(count) * wStep(textView))
            resetVim(); return true

        case "g":
            if pendingIsG {
                moveToLine(textView, count, total: lineCount(textView))
                resetVim(); return true
            }
            pendingIsG = true
            return true

        case "G":
            if count > 1 {
                moveToLine(textView, count, total: lineCount(textView))
            } else {
                scrollByFraction(textView, 1.0)
            }
            resetVim(); return true

        case "H":
            goToScreenFraction(textView, 0.0)
            resetVim(); return true
        case "M":
            goToScreenFraction(textView, 0.5)
            resetVim(); return true
        case "L":
            goToScreenFraction(textView, 0.97)
            resetVim(); return true

        case "$":
            scrollHorizontally(textView, delta: .infinity)
            resetVim(); return true

        default:
            break
        }

        // If a pending count was held without a matching motion, discard it.
        resetVim()
        return true
    }

    // MARK: – Vim helpers

    private func resetVim() { pendingCount = 0; pendingIsG = false }

    private func scrollView(of textView: NSTextView) -> NSScrollView? { textView.enclosingScrollView }

    private func horizontalMax(for scrollView: NSScrollView) -> CGFloat {
        max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.contentView.bounds.width)
    }

    private func hStep(_ textView: NSTextView) -> CGFloat {
        (textView.font?.pointSize ?? 14) * 0.6 * 8
    }

    private func wStep(_ textView: NSTextView) -> CGFloat {
        (textView.font?.pointSize ?? 14) * 0.6 * 4
    }

    private func scrollHorizontally(_ textView: NSTextView, delta: CGFloat) {
        guard let scrollView = scrollView(of: textView) else { return }
        let cv = scrollView.contentView
        let current = cv.bounds.origin
        let maxX = horizontalMax(for: scrollView)
        let nx: CGFloat
        if delta == .infinity { nx = maxX }
        else if delta == -.infinity { nx = 0 }
        else { nx = min(max(0, current.x + delta), maxX) }
        guard nx != current.x else { return }
        cv.scroll(to: NSPoint(x: nx, y: current.y))
    }

    private func scrollByFraction(_ textView: NSTextView, _ fraction: CGFloat) {
        guard let scrollView = scrollView(of: textView) else { return }
        let cv = scrollView.contentView
        let dy = cv.bounds.height * fraction
        let current = cv.bounds.origin
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - cv.bounds.height)
        let ny = min(max(0, current.y + dy), maxY)
        guard ny != current.y else { return }
        cv.scroll(to: NSPoint(x: current.x, y: ny))
    }

    private func lineCount(_ textView: NSTextView) -> Int {
        max(1, textView.string.components(separatedBy: .newlines).count)
    }

    private func moveToLine(_ textView: NSTextView, _ line: Int, total: Int) {
        guard total > 0 else { return }
        let clamped = min(max(line, 1), total)
        let frac = total == 1 ? 0 : Double(clamped - 1) / Double(total - 1)
        let ns = textView.string as NSString
        let index = min(Int(Double(ns.length) * frac), ns.length)
        textView.scrollRangeToVisible(NSRange(location: index, length: 0))
    }

    private func goToScreenFraction(_ textView: NSTextView, _ fraction: CGFloat) {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
        let visible = textView.visibleRect
        let x = visible.midX
        let y = visible.minY + visible.height * fraction
        let index = layout.characterIndex(for: NSPoint(x: x, y: y), in: container,
                                          fractionOfDistanceBetweenInsertionPoints: nil)
        textView.scrollRangeToVisible(NSRange(location: min(index, (textView.string as NSString).length), length: 0))
    }
}
