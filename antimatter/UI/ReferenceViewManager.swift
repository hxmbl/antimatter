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
        status.wrappedValue = FooterStatus(preview: "q to close · j/k scroll", answerToCopy: nil)
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

    /// Keystroke swallowed by the reference view. Navigation scrolls,
    /// `q`/Escape close; everything else is consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isInHelpView, let textView = helpTextView else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // System keys pass through: ⌘F still searches, ⌘Q still quits.
        if flags.contains(.command) || flags.contains(.control) { return false }
        // Escape: close the reference (instead of hiding the pane).
        if event.keyCode == 53 { exit(); return true }
        guard let characters = event.charactersIgnoringModifiers else { return true }
        switch characters {
        case "q", "Q":
            exit()
            return true
        case "j": textView.scrollLineDown(nil); return true
        case "k": textView.scrollLineUp(nil); return true
        case " ", "f": textView.scrollPageDown(nil); return true
        case "b": textView.scrollPageUp(nil); return true
        case "g": textView.scrollToBeginningOfDocument(nil); return true
        case "G": textView.scrollToEndOfDocument(nil); return true
        default: break
        }
        // Arrow / Page Up / Page Down / Home / End still scroll the
        // reference text via native responder navigation.
        let navKeyCodes: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        if navKeyCodes.contains(event.keyCode) { return false }
        // Everything else is consumed so it never modifies the reference.
        return true
    }
}
