import SwiftUI
import AppKit

/// What the pane's footer says about the caret line: a live preview of what
/// return would do, plus the copyable answer when the line is committed.
struct FooterStatus: Equatable {
    var preview = ""
    var answerToCopy: String?
    var wordCount: Int = 0
    var charCount: Int = 0
    var readingEase: Double? = nil
}

/// Plain-text Markdown editor backed by NSTextView, styled by `PaneStyle`.
struct PaneEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var status: FooterStatus
    var noteStore: NoteStore

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, status: $status, noteStore: noteStore)
    }

    func makeNSView(context: Context) -> OverlayScrollView {
        let textView = PaneTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isIncrementalSearchingEnabled = true
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
        textView.textColor = PaneStyle.textNSColor
        textView.insertionPointColor = PaneStyle.textNSColor
        textView.font = .systemFont(ofSize: PaneStyle.fontSize)
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = Self.makeTypingAttributes()
        textView.linkTextAttributes = Self.linkTextAttributes
        // Markdown source must survive typing verbatim: smart quotes,
        // automatic dashes, replacements, links, data detection, and
        // spelling correction are all disabled.
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
            coordinator?.referenceViewManager.handleKey(event) ?? false
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
        context.coordinator.ownedTextView = textView
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: OverlayScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PaneTextView else { return }
        // The help view swaps the whole buffer; a SwiftUI re-render (timer
        // chips, notices, settings) must not clobber it back to the note —
        // and a settings-side font change must not restyle the reference
        // text either, which re-rendering it as Markdown would do.
        guard !context.coordinator.referenceViewManager.isInHelpView else { return }
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
            .foregroundColor: PaneStyle.textNSColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private static var linkTextAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: PaneStyle.accentNSColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var status: Binding<FooterStatus>
        let noteStore: NoteStore
        let highlighter = MarkdownHighlighter()
        private var deferredPassTask: Task<Void, Never>?
        private var pendingRender: DispatchWorkItem?
        private var pendingStatusUpdate: DispatchWorkItem?
        private var appliedFontSize: CGFloat = PaneStyle.fontSize
        private var appliedThemeID = PaneTheme.current.id
        /// Set while undo replays are landing; automatic rewrites stand
        /// down until a real keystroke arrives, so ⌘Z always wins and stays
        /// won no matter how slowly the user walks back through history.
        private var autoRewritesSuppressed = false
        /// Start of the `.`-token the completion window is already parked on;
        /// the window follows further typing on its own, so re-calling
        /// `complete(_:)` would only close and re-open it.
        private var completionAnchor: Int?
        lazy var referenceViewManager: ReferenceViewManager = ReferenceViewManager(
            highlighter: highlighter,
            status: status,
            updateFooterStatus: { [weak self] textView in self?.updateFooterStatus(textView) }
        )
        weak var ownedTextView: PaneTextView?

        init(text: Binding<String>, status: Binding<FooterStatus>, noteStore: NoteStore) {
            self.text = text
            self.status = status
            self.noteStore = noteStore
            super.init()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            autoRewritesSuppressed = textView.undoManager?.isUndoing == true
            let newText = textView.string
            scheduleRender(textView)
            schedulePendingCalculation(textView)
            scheduleReactivePass(textView)
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
            scheduleStatusUpdate(textView)
            scheduleCompletion(textView)
        }

        /// Wait until AppKit finishes the current edit transaction before
        /// applying Markdown attributes. Rendering synchronously from
        /// `textDidChange` can influence the typing attributes used by the
        /// same keystroke, making newly typed Unicode look corrupted.
        private func scheduleRender(_ textView: NSTextView) {
            pendingRender?.cancel()
            let render = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlighter.refresh(textView)
            }
            pendingRender = render
            DispatchQueue.main.async(execute: render)
        }

        /// Footer state is SwiftUI state. Defer it until AppKit has finished
        /// delivering the edit or selection notification so panel creation
        /// and focus changes do not mutate SwiftUI during view updates.
        private func scheduleStatusUpdate(_ textView: NSTextView) {
            pendingStatusUpdate?.cancel()
            let update = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.updateFooterStatus(textView)
            }
            pendingStatusUpdate = update
            DispatchQueue.main.async(execute: update)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            highlighter.refresh(textView)
            guard !referenceViewManager.isInHelpView else { return }
            scheduleStatusUpdate(textView)
        }

        /// Keep typed text literal. Automatic punctuation substitutions are
        /// deliberately disabled so ordinary hyphens, flags, and pasted text
        /// never turn into unexpected Unicode characters.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !referenceViewManager.isInHelpView else { return true }
            if let replacement = replacementString, replacement == "\n" {
                let ns = textView.string as NSString
                var lineStart = 0, lineEnd = 0, contentsEnd = 0
                ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: affectedCharRange.location, length: 0))
                let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                let patterns = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] ",
                                "+ [ ] ", "+ [x] ", "+ [X] "]
                for pattern in patterns {
                    if line.hasPrefix(pattern) {
                        textView.insertText("\n\(pattern)", replacementRange: affectedCharRange)
                        return false
                    }
                }
            }
            return true
        }

        /// Return pressed: run any recognised intent on the caret's line
        /// before the newline lands. The newline is never consumed unless
        /// the intent took over the buffer (`.help` opens the reference).
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !referenceViewManager.isInHelpView else {
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
            let themeID = PaneTheme.current.id
            let textColorChanged = !(textView.textColor?.isEqual(PaneStyle.textNSColor) ?? false)
            guard size != appliedFontSize || themeID != appliedThemeID || textColorChanged else { return }
            appliedFontSize = size
            appliedThemeID = themeID
            textView.font = .systemFont(ofSize: size)
            textView.textColor = PaneStyle.textNSColor
            textView.insertionPointColor = PaneStyle.textNSColor
            textView.typingAttributes = PaneEditor.makeTypingAttributes(fontSize: size)
            textView.linkTextAttributes = PaneEditor.linkTextAttributes
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
                TimerCenter.shared.start(duration: timer.duration, label: timer.label, name: timer.name, fullScreen: timer.fullScreen)
                if timer.clamped {
                    NoticeCenter.shared.show("Timers cap at 30 days — shortened.")
                }
                if timer.fullScreen, let active = TimerCenter.shared.timers.first {
                    TimerOverlayWindow.shared.show(timer: active)
                }
            case .startPomodoro(let work, let rest, let cycles):
                TimerCenter.shared.startPomodoro(work: work, rest: rest, cycles: cycles)
            case .startStopwatch(let label):
                StopwatchCenter.shared.start(label: label)
            case .cancelStopwatches:
                let count = StopwatchCenter.shared.stopwatches.count
                StopwatchCenter.shared.cancelAll()
                NoticeCenter.shared.show(count == 0 ? "No stopwatches to cancel." : (count == 1 ? "Stopwatch cancelled." : "\(count) stopwatches cancelled."))
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
            case .newNote:
                noteStore.create()
                return true
            case .export(let destination):
                exportNote(to: destination)
            case .showHelp:
                referenceViewManager.enter(textView, content: IntentExecution.helpText)
                return true
            case .showSettings:
                (NSApplication.shared.delegate as? AppDelegate)?.openSettings(nil)
            case .showDebug:
                referenceViewManager.enter(textView, content: DebugReport.generate())
                return true
            case .showFindPanel:
                let item = NSMenuItem()
                item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
                textView.performTextFinderAction(item)
                return true
            case .replaceAll(let find, let replace):
                performGlobalReplace(find: find, replacement: replace, textView: textView)
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

        /// `.export`: send the whole note somewhere local. Reuses the same
        /// text the note owns; no network involved.
        private func exportNote(to destination: ExportDestination) {
            guard !referenceViewManager.isInHelpView else { return }
            do {
                let outcome = try ExportCenter.export(destination, text: text.wrappedValue)
                NoticeCenter.shared.show(outcome)
                DebugLog.log("export — \(destination.rawValue)")
            } catch {
                NoticeCenter.shared.show(error.localizedDescription.isEmpty
                    ? "Export cancelled."
                    : error.localizedDescription)
            }
        }

        private func performGlobalReplace(find: String, replacement: String, textView: NSTextView) {
            // Strip the command line first, then count and replace against the
            // remaining body — otherwise an occurrence inside the command line
            // itself inflates both the count and the rewritten text.
            let commandLine = (textView.string as NSString).lineRange(for: textView.selectedRange())
            if textView.shouldChangeText(in: commandLine, replacementString: "") {
                textView.textStorage?.replaceCharacters(in: commandLine, with: "")
                textView.didChangeText()
            }
            let current = textView.string
            let ns = current as NSString
            var count = 0
            var searchRange = NSRange(location: 0, length: ns.length)
            while true {
                let foundRange = ns.range(of: find, options: [], range: searchRange)
                if foundRange.location == NSNotFound { break }
                count += 1
                let nextStart = foundRange.location + foundRange.length
                guard nextStart <= ns.length else { break }
                searchRange = NSRange(location: nextStart, length: ns.length - nextStart)
            }
            guard count > 0 else {
                NoticeCenter.shared.show("\"\(find)\" not found")
                return
            }
            let result = ns.replacingOccurrences(of: find, with: replacement)
            if textView.shouldChangeText(in: NSRange(location: 0, length: ns.length), replacementString: result) {
                textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: ns.length), with: result)
                textView.didChangeText()
            }
            NoticeCenter.shared.show("Replaced \(count) occurrence\(count == 1 ? "" : "s") of \"\(find)\"")
        }

        /// Live footer: preview what return would do on the caret line, and
        /// offer the committed answer for copying. Suppressed in help view.
        private func updateFooterStatus(_ textView: NSTextView) {
            guard !referenceViewManager.isInHelpView else { return }
            guard let contentRange = caretLineRange(in: textView) else {
                status.wrappedValue = FooterStatus()
                return
            }
            let line = (textView.string as NSString).substring(with: contentRange)
            let text = textView.string
            let words = text.split(separator: /\s+/).count
            let chars = text.count
            let ease = ReadingMetrics.fleschKincaidEase(text)
            status.wrappedValue = FooterStatus(
                preview: IntentExecution.preview(forLine: line, in: textView.string) ?? "",
                answerToCopy: IntentExecution.answer(fromLine: line),
                wordCount: words,
                charCount: chars,
                readingEase: ease)
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
                guard let text = try? await ImageText.recognize(image), !text.isEmpty else { return }
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
