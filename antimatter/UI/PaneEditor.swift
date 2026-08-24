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
        textView.typingAttributes = Self.makeTypingAttributes()
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
        textView.onDroppedImage = { [weak coordinator = context.coordinator] image in
            coordinator?.recognizeAndInsert(image)
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
        guard let textView = scrollView.documentView as? PaneTextView else { return }
        // A settings-side font change arrives as a plain re-render.
        context.coordinator.applyFontSizeIfChanged(to: textView)
        guard textView.string != text else { return }
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

    private static func makeTypingAttributes(fontSize: CGFloat = PaneStyle.fontSize) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let highlighter = MarkdownHighlighter()
        private var deferredPassTask: Task<Void, Never>?
        private var appliedFontSize: CGFloat = PaneStyle.fontSize

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            highlighter.refresh(textView)
            schedulePendingCalculation(textView)
            scheduleReactivePass(textView)
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

        /// A settings-side font change lands here: restyle typing and
        /// re-render everything at the new size.
        func applyFontSizeIfChanged(to textView: NSTextView) {
            let size = PaneStyle.fontSize
            guard size != appliedFontSize else { return }
            appliedFontSize = size
            textView.font = .systemFont(ofSize: size)
            textView.typingAttributes = PaneEditor.makeTypingAttributes(fontSize: size)
            highlighter.render(textView)
        }

        // MARK: Intents

        /// Typing `=` after a full expression asks for the answer inline:
        /// `384 * 27 =` becomes `384 * 27 = 10368`. Deferred out of the
        /// did-change notification so text storage is never mutated re-entrantly.
        private func schedulePendingCalculation(_ textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      !IntentExecution.isDeferredCommitStale(
                        viewText: textView.string,
                        boundText: self.text.wrappedValue,
                        viewHasFocus: textView.window?.firstResponder == textView)
                else { return }
                self.commitCalculation(textView, in: self.caretLineRange(in: textView))
            }
        }

        /// Reactive results: once typing quiets down, committed lines whose
        /// stored answers drifted (a definition changed) are recomputed in
        /// place. Debounced so it never fights an active keystroke.
        private func scheduleReactivePass(_ textView: NSTextView) {
            deferredPassTask?.cancel()
            deferredPassTask = Task { [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.runReactivePass(textView)
            }
        }

        private func runReactivePass(_ textView: NSTextView?) {
            guard let textView,
                  !IntentExecution.isDeferredCommitStale(
                    viewText: textView.string,
                    boundText: text.wrappedValue,
                    viewHasFocus: textView.window?.firstResponder == textView)
            else { return }
            applyCommits(IntentExecution.staleResultCommits(in: textView.string), to: textView)
        }

        private func executeLineIntent(_ textView: NSTextView) {
            guard let contentRange = caretLineRange(in: textView) else { return }
            let line = (textView.string as NSString).substring(with: contentRange)
            switch IntentExecution.action(forLine: line, in: textView.string) {
            case .startTimer(let timer):
                TimerCenter.shared.start(duration: timer.duration, label: timer.label)
            case .startPasteStream:
                PasteStream.shared.startStreaming()
            case .insertAggregate(let kind):
                if let commit = IntentExecution.aggregateCommit(kind, keyword: line, in: textView.string, at: contentRange) {
                    applyCommit(commit, to: textView)
                }
            case .rewriteCalculation:
                commitCalculation(textView, in: contentRange)
            case .rewriteLine(let replacement):
                textView.breakUndoCoalescing()
                textView.insertText(replacement, replacementRange: contentRange)
            case .nothing:
                break
            }
        }

        /// Applies commits bottom-up so earlier ranges survive later
        /// insertions, keeps one undo step, and restores the caret sensibly
        /// when it sat inside a rewritten line.
        private func applyCommits(_ commits: [IntentExecution.Commit], to textView: NSTextView) {
            guard !commits.isEmpty else { return }
            let ordered = commits.sorted { $0.range.location > $1.range.location }
            let selection = textView.selectedRange()
            let caretHit = ordered.first {
                NSLocationInRange(selection.location, NSRange(
                    location: $0.range.location,
                    length: $0.range.length + 1))
            }
            textView.breakUndoCoalescing()
            for commit in ordered {
                textView.insertText(commit.replacement, replacementRange: commit.range)
            }
            if let caretHit {
                let offset = max(0, min(
                    selection.location - caretHit.range.location,
                    (caretHit.replacement as NSString).length))
                textView.setSelectedRange(NSRange(location: caretHit.range.location + offset, length: 0))
            } else {
                textView.setSelectedRange(selection)
            }
        }

        private func commitCalculation(_ textView: NSTextView, in contentRange: NSRange?) {
            guard let commit = IntentExecution.calculationCommit(in: textView.string, at: contentRange) else { return }
            applyCommit(commit, to: textView)
        }

        private func applyCommit(_ commit: IntentExecution.Commit, to textView: NSTextView) {
            textView.breakUndoCoalescing()
            textView.insertText(commit.replacement, replacementRange: commit.range)
        }

        /// Screenshot → text: OCR the dropped image on-device and append it.
        func recognizeAndInsert(_ image: NSImage) {
            Task {
                guard let text = await ImageText.recognize(image), !text.isEmpty else { return }
                self.text.wrappedValue += (self.text.wrappedValue.hasSuffix("\n") || self.text.wrappedValue.isEmpty ? "" : "\n") + text + "\n"
            }
        }

        /// The current line excluding its trailing newline, or nil when the
        /// selection spans more than one position.
        private func caretLineRange(in textView: NSTextView) -> NSRange? {
            IntentExecution.caretLineRange(in: textView.string, selection: textView.selectedRange())
        }
    }
}
