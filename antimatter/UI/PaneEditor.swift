import SwiftUI
import AppKit

/// What the pane's footer says about the caret line: a live preview of what
/// return would do, plus the copyable answer when the line is committed.
struct FooterStatus: Equatable {
    var preview = ""
    var answerToCopy: String?
}

/// Plain-text Markdown editor backed by NSTextView, styled by `PaneStyle`.
struct PaneEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var status: FooterStatus

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, status: $status)
    }

    func makeNSView(context: Context) -> OverlayScrollView {
        let textView = PaneTextView()
        textView.delegate = context.coordinator
        textView.string = text
        // Editing state is made explicit instead of inherited: a pane text
        // view that ever ends up non-editable silently swallows every
        // keystroke with an alert beep, so guard the invariant here.
        textView.isEditable = true
        textView.isSelectable = true
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
        textView.onHelpKeyDown = { [weak coordinator = context.coordinator] event in
            coordinator?.handleHelpViewKey(event) ?? false
        }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Explicit sizing limits make the layout manager grow the frame with
        // the text. Without them the document view stays clipped to the scroll
        // view's height and there is nothing to scroll, no matter how long
        // the note gets (reproduced: usedH ≈ 3360 yet frame stayed at clip H).
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        // The help view swaps the whole buffer; a SwiftUI re-render (timer
        // chips, notices, settings) must not clobber it back to the note.
        guard !context.coordinator.isInHelpView else { return }
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
        var status: Binding<FooterStatus>
        let highlighter = MarkdownHighlighter()
        private var deferredPassTask: Task<Void, Never>?
        private var appliedFontSize: CGFloat = PaneStyle.fontSize
        /// Set while undo replays are landing; automatic rewrites stand
        /// down until a real keystroke arrives, so ⌘Z always wins and stays
        /// won no matter how slowly the user walks back through history.
        private var autoRewritesSuppressed = false
        /// Start of the `.`-token the completion window is already parked on;
        /// the window follows further typing on its own, so re-calling
        /// `complete(_:)` would only close and re-open it.
        private var completionAnchor: Int?
        /// True while the pane shows a full-screen reference (`.help`,
        /// `.debug`) — a less-like view. Typing is swallowed; `j`/`k` scroll,
        /// `q` or Escape restores the note. The editor keeps its binding
        /// untouched so the note survives.
        var isInHelpView = false
        /// The note text, caret, and editor configuration restored when
        /// leaving the reference view.
        private var helpSnapshot: (text: String, selection: NSRange, font: NSFont, isHorizontallyResizable: Bool, widthTracksTextView: Bool, containerSize: NSSize)?
        /// The text view hosting the reference, so `q`/Escape can restore it.
        private weak var helpTextView: NSTextView?

        init(text: Binding<String>, status: Binding<FooterStatus>) {
            self.text = text
            self.status = status
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Programmatic updates never reach the delegate, so any
            // did-change is either a live keystroke or an undo/redo replay.
            autoRewritesSuppressed = textView.undoManager?.isUndoing == true
            let newText = textView.string
            highlighter.refresh(textView)
            schedulePendingCalculation(textView)
            scheduleReactivePass(textView)
            // A no-op write would still publish and ripple through SwiftUI;
            // skip it so typing a character at a collapsed marker (which
            // may emit a did-change with identical text) stays silent.
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
            updateFooterStatus(textView)
            scheduleCompletion(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            highlighter.refresh(textView)
            guard !isInHelpView else { return }
            updateFooterStatus(textView)
        }

        /// Return pressed: run any recognised intent on the caret's line
        /// before the newline lands. The newline is never consumed unless
        /// the intent took over the buffer (`.help` opens the reference).
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !isInHelpView else {
                // Read-only reference view: navigation still scrolls the
                // help text, every other command key is swallowed.
                let name = NSStringFromSelector(commandSelector)
                return !(name.hasPrefix("move") || name.hasPrefix("scroll") || name.hasPrefix("page"))
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return executeLineIntent(textView)
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
                      !autoRewritesSuppressed,
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
        /// place. Debounced so it never fights an active keystroke, and
        /// suppressed after an undo — otherwise the pass would instantly
        /// reapply whatever ⌘Z just removed.
        /// Reactive results: once typing quiets down, committed lines whose
        /// stored answers drifted (a definition changed) are recomputed in
        /// place. Debounced so it never fights an active keystroke, and
        /// suppressed while undo is in play — the pass would otherwise
        /// instantly reapply whatever ⌘Z just removed.
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
                  !autoRewritesSuppressed,
                  !IntentExecution.isDeferredCommitStale(
                    viewText: textView.string,
                    boundText: text.wrappedValue,
                    viewHasFocus: textView.window?.firstResponder == textView)
            else { return }
            applyCommits(IntentExecution.staleResultCommits(in: textView.string), to: textView)
        }

        /// Returns true when the intent consumed the return key (the whole buffer
        /// was taken over, so the default newline must not land).
        @discardableResult
        private func executeLineIntent(_ textView: NSTextView) -> Bool {
            guard let contentRange = caretLineRange(in: textView) else { return false }
            let line = (textView.string as NSString).substring(with: contentRange)
            switch IntentExecution.action(forLine: line, in: textView.string) {
            case .startTimer(let timer):
                TimerCenter.shared.start(duration: timer.duration, label: timer.label)
                if timer.clamped {
                    NoticeCenter.shared.show("Timers cap at 30 days — shortened.")
                }
            case .startReminder(let reminder):
                if ReminderCenter.shared.schedule(message: reminder.message, at: reminder.date) {
                    NoticeCenter.shared.show("Reminder in \(ReminderCenter.format(reminder.date.timeIntervalSinceNow)) — \(reminder.message)")
                } else {
                    NoticeCenter.shared.show("Reminder needs a future time.")
                }
            case .cancelAllTimers:
                let count = TimerCenter.shared.timers.count
                TimerCenter.shared.cancelAll()
                NoticeCenter.shared.show(count == 0 ? "No running timers to cancel." : (count == 1 ? "Timer cancelled." : "\(count) timers cancelled."))
            case .cancelAllReminders:
                let count = ReminderCenter.shared.reminders.count
                ReminderCenter.shared.cancelAll()
                NoticeCenter.shared.show(count == 0 ? "No pending reminders to cancel." : (count == 1 ? "Reminder cancelled." : "\(count) reminders cancelled."))
            case .startPasteStream:
                PasteStream.shared.startStreaming()
            case .showHelp:
                enterReferenceView(textView, content: IntentExecution.helpText)
                return true
            case .showSettings:
                (NSApplication.shared.delegate as? AppDelegate)?.openSettings(nil)
            case .showDebug:
                enterReferenceView(textView, content: debugReport())
                return true
            case .hint(let message):
                NoticeCenter.shared.show(message)
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
            return false
        }

        /// Live footer: preview what return would do on the caret line, and
        /// offer the committed answer for copying. Suppressed in help view.
        private func updateFooterStatus(_ textView: NSTextView) {
            guard !isInHelpView else { return }
            guard let contentRange = caretLineRange(in: textView) else {
                status.wrappedValue = FooterStatus()
                return
            }
            let line = (textView.string as NSString).substring(with: contentRange)
            status.wrappedValue = FooterStatus(
                preview: IntentExecution.preview(forLine: line, in: textView.string) ?? "",
                answerToCopy: IntentExecution.answer(fromLine: line))
        }

        // MARK: Full-screen reference view (help / debug)

        /// Enter a full-screen reference block (`.help`, `.debug`): the note
        /// and its editor configuration are stashed, the content takes the
        /// whole buffer, and keystrokes are swallowed except navigation and
        /// `q`/Escape.
        private func enterReferenceView(_ textView: NSTextView, content: String) {
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
                .foregroundColor: NSColor.labelColor,
            ], range: NSRange(location: 0, length: (content as NSString).length))
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            textView.window?.makeFirstResponder(textView)
            status.wrappedValue = FooterStatus(preview: "q to close · j/k scroll", answerToCopy: nil)
        }

        /// Restore the stashed note and normal editing.
        private func exitReferenceView() {
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

        /// Keystroke swallowed by the full-screen reference view. `j`/`k`,
        /// Page keys, and space/b/g/G scroll; arrows, Page Up/Down, Home/End
        /// and system shortcuts (⌘/⌃) pass through; `q` and Escape close.
        func handleHelpViewKey(_ event: NSEvent) -> Bool {
            guard isInHelpView, let textView = helpTextView else { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // System keys pass through: ⌘F still searches, ⌘Q still quits.
            if flags.contains(.command) || flags.contains(.control) { return false }
            // Escape: close the reference (instead of hiding the pane).
            if event.keyCode == 53 { exitReferenceView(); return true }
            guard let characters = event.charactersIgnoringModifiers else { return true }
            switch characters {
            case "q", "Q":
                exitReferenceView()
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

        /// A live diagnostics + recent-event report for `.debug`.
        private func debugReport() -> String {
            var out: [String] = []
            out.append("Antimatter — debug")
            out.append("")
            let fileURL = ScratchStore.defaultFileURL()
            out.append("note:    \(fileURL.path)")
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                out.append("         \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            }
            out.append("font:    \(PaneStyle.fontSize)pt")
            let timers = TimerCenter.shared.timers
            if timers.isEmpty {
                out.append("timers:  none")
            } else {
                out.append("timers:  \(timers.count)")
                for timer in timers {
                    out.append("         • \(timer.label.isEmpty ? "unlabelled" : timer.label) · \(TimerCenter.format(timer.duration))")
                }
            }
            let reminders = ReminderCenter.shared.reminders
            if reminders.isEmpty {
                out.append("remind:  none")
            } else {
                out.append("remind:  \(reminders.count)")
                for reminder in reminders {
                    out.append("         • \(reminder.message) · \(ReminderCenter.format(reminder.date.timeIntervalSinceNow))")
                }
            }
            out.append("paste:   \(PasteStream.shared.isStreaming ? "streaming" : "idle")")
            out.append("")
            let logLines = DebugLog.shared.lines
            out.append("log (\(logLines.count)):")
            if logLines.isEmpty {
                out.append("         (nothing captured yet)")
            } else {
                out.append(contentsOf: logLines.map { "         \($0)" })
            }
            return out.joined(separator: "\n")
        }

        // MARK: Dot-command autocompletion

        /// Native completion list while typing a partial dot-command. The
        /// range NSTextView reports starts at the letters after the dot, so
        /// it is walked back to the token's start for the `.partial` prefix.
        func textView(
            _ textView: NSTextView,
            completionsForPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String]? {
            guard let ns = textView.string as NSString? else { return nil }
            var start = charRange.location
            while start > 0 {
                let character = ns.character(at: start - 1)
                if character == unichar(" ") || character == unichar("\t") || character == unichar("\n") {
                    break
                }
                start -= 1
            }
            let tokenRange = NSRange(location: start, length: NSMaxRange(charRange) - start)
            guard tokenRange.length > 0 else { return nil }
            let token = ns.substring(with: tokenRange)
            guard let matches = IntentExecution.completions(for: token) else { return nil }
            index?.pointee = 0
            return matches
        }

        private var completionTask: Task<Void, Never>?

        /// Auto-open the completion window once per `.partial` token via a
        /// debounce, so the command list appears exactly when a tap on `.`
        /// gets followed by a letter. `complete(_:)` closes an already-visible
        /// window, which is why the anchor guards against re-calling it; the
        /// window tracks further typing on its own.
        private func scheduleCompletion(_ textView: NSTextView) {
            completionTask?.cancel()
            completionTask = Task { [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled, let self, let textView else { return }
                guard !autoRewritesSuppressed,
                      textView.window?.firstResponder == textView,
                      textView.selectedRange().length == 0
                else { return }
                let ns = textView.string as NSString
                let location = textView.selectedRange().location
                guard location > 0, location <= ns.length else { return }
                var start = location
                while start > 0 {
                    let character = ns.character(at: start - 1)
                    if character == unichar(" ") || character == unichar("\t") || character == unichar("\n") {
                        break
                    }
                    start -= 1
                }
                guard start != completionAnchor, location - start > 0 else { return }
                let token = ns.substring(with: NSRange(location: start, length: location - start))
                guard let matches = IntentExecution.completions(for: token),
                      matches.contains(where: { $0.trimmingCharacters(in: .whitespaces) != token })
                else { return }
                completionAnchor = start
                textView.complete(textView)
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
