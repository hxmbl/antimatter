import SwiftUI
import AppKit

/// Plain-text Markdown editor backed by NSTextView, styled by `PaneStyle`.
struct PaneEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> OverlayScrollView {
        let textView = PaneTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = .systemFont(ofSize: PaneStyle.fontSize)
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = Self.typingAttributes
        textView.linkTextAttributes = Self.linkTextAttributes
        // Markdown source must survive typing verbatim: smart quotes would
        // curl `"`, smart dashes would turn `--` into an en dash, and
        // automatic link detection would fight our own parser.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        if PaneStyle.hidesOnEscape {
            textView.onCancelOperation = { [weak textView] in
                textView?.window?.orderOut(nil)
            }
        }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 2, height: 2)

        let scrollView = OverlayScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = PaneStyle.showScrollerWhileScrolling
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.autoresizingMask = [.width, .height]

        context.coordinator.highlighter.render(textView)
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: OverlayScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PaneTextView,
              textView.string != text else { return }
        let selected = textView.selectedRanges.compactMap { proto -> NSValue? in
            var range = proto.rangeValue
            guard range.location != NSNotFound else { return nil }
            let length = (text as NSString).length
            if range.location > length { range.location = length; range.length = 0 }
            if range.length > length - range.location { range.length = length - range.location }
            return NSValue(range: range)
        }
        textView.string = text
        if !selected.isEmpty {
            textView.selectedRanges = selected
        }
        context.coordinator.highlighter.render(textView)
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = PaneStyle.lineSpacing
        return style
    }

    private static var typingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: PaneStyle.fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private static var linkTextAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let highlighter = MarkdownHighlighter()

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            highlighter.refresh(textView)
            schedulePendingCalculation(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            highlighter.refresh(textView)
        }

        /// Return pressed: run any recognised intent on the caret's line
        /// before the newline lands. The newline is never consumed.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            executeLineIntent(textView)
            return false
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            NSWorkspace.shared.open(url)
            return true
        }

        // MARK: Intents

        /// Typing `=` after a full expression asks for the answer inline:
        /// `384 * 27 =` becomes `384 * 27 = 10368`. Deferred out of the
        /// did-change notification so text storage is never mutated re-entrantly.
        private func schedulePendingCalculation(_ textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      textView.string == self.text.wrappedValue,
                      textView.window?.firstResponder == textView  // user may have moved on
                else { return }
                self.commitCalculation(textView, in: self.caretLineRange(in: textView))
            }
        }

        private func executeLineIntent(_ textView: NSTextView) {
            guard let contentRange = caretLineRange(in: textView) else { return }
            let line = (textView.string as NSString).substring(with: contentRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A trailing `=` means the user is asking for a calculation,
            // never starting a timer (`timer 5 =`).
            guard !trimmed.hasSuffix("=") else { return }

            if let timer = IntentParser.parseTimer(trimmed) {
                TimerCenter.shared.start(duration: timer.duration, label: timer.label)
                return
            }
            commitCalculation(textView, in: contentRange)
        }

        private func commitCalculation(_ textView: NSTextView, in contentRange: NSRange?) {
            guard let contentRange, contentRange.length > 0 else { return }
            let ns = textView.string as NSString
            let line = ns.substring(with: contentRange)
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            let calculation = IntentParser.pendingCalculation(trimmedLine)
                ?? IntentParser.parseCalculation(trimmedLine)
            guard let calculation else { return }
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let replacement = indent + calculation.expression + " = " + IntentParser.format(calculation.result)
            textView.breakUndoCoalescing()
            textView.insertText(replacement, replacementRange: contentRange)
        }

        /// The current line excluding its trailing newline, or nil when the
        /// selection spans more than one position.
        private func caretLineRange(in textView: NSTextView) -> NSRange? {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }
            let ns = textView.string as NSString
            guard selection.location <= ns.length else { return nil }
            var range = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == unichar(10) {
                range.length -= 1
            }
            return range
        }
    }
}
