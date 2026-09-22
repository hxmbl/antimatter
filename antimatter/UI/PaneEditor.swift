import SwiftUI
import AppKit

struct FooterStatus: Equatable {
    var preview = ""
    var answerToCopy: String?
    var wordCount: Int = 0
}

struct PaneEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var status: FooterStatus
    @Binding var topTextLevel: CGFloat
    var noteStore: NoteStore

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, status: $status, topTextLevel: $topTextLevel, noteStore: noteStore)
    }

    func makeNSView(context: Context) -> OverlayScrollView {
        let textView = PaneTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isIncrementalSearchingEnabled = true
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
        textView.onTabKeyDown = { [weak coordinator = context.coordinator] in
            coordinator?.attemptTabCompletion() ?? false
        }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
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
        context.coordinator.clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak textView] _ in
            textView?.reportTopTextLevel()
        }
        textView.onTopTextLevelChange = { [weak coordinator = context.coordinator] level in
            coordinator?.topTextLevel.wrappedValue = level
        }
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
            textView.reportTopTextLevel()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: OverlayScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PaneTextView else { return }
        guard !context.coordinator.referenceViewManager.isInHelpView else { return }
        context.coordinator.applyFontSizeIfChanged(to: textView)
        textView.reportTopTextLevel()
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
        var topTextLevel: Binding<CGFloat>
        let noteStore: NoteStore
        let highlighter = MarkdownHighlighter()
        var clipBoundsObserver: NSObjectProtocol?
        private var deferredPassTask: Task<Void, Never>?
        private var deferredCalculationTask: Task<Void, Never>?
        private var pendingRender: DispatchWorkItem?
        private var pendingStatusUpdate: DispatchWorkItem?
        private var appliedFontSize: CGFloat = PaneStyle.fontSize
        private var appliedThemeID = PaneTheme.current.id
        /// Undo replays suppress automatic rewrites until a real keystroke arrives.
        private var autoRewritesSuppressed = false
        private var suppressedTokenStart: Int?
        private var completionTask: Task<Void, Never>?
        private let completionPanel = CommandCompletionPanel()
        /// Dispatch source timer for minute-boundary .time updates
        private var minuteBoundaryTimer: DispatchSourceTimer?
        lazy var referenceViewManager: ReferenceViewManager = ReferenceViewManager(
            highlighter: highlighter,
            status: status,
            updateFooterStatus: { [weak self] textView in self?.updateFooterStatus(textView) }
        )
        weak var ownedTextView: PaneTextView?

        init(text: Binding<String>, status: Binding<FooterStatus>, topTextLevel: Binding<CGFloat>, noteStore: NoteStore) {
            self.text = text
            self.status = status
            self.topTextLevel = topTextLevel
            self.noteStore = noteStore
            super.init()
        }

        deinit {
            if let clipBoundsObserver {
                NotificationCenter.default.removeObserver(clipBoundsObserver)
            }
            minuteBoundaryTimer?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            (textView as? PaneTextView)?.reportTopTextLevel()
            autoRewritesSuppressed = textView.undoManager?.isUndoing == true
            let newText = textView.string
            scheduleRender(textView)
            schedulePendingCalculation(textView)
            scheduleReactivePass(textView)
            if text.wrappedValue != newText {
                text.wrappedValue = newText
            }
            scheduleStatusUpdate(textView)
            if completionPanel.isShown {
                syncCompletion(textView)
            } else {
                scheduleCompletion(textView)
            }
        }

        /// Defer Markdown rendering until AppKit finishes the current edit
        /// transaction; rendering synchronously can corrupt newly typed Unicode.
        /// A short coalescing window also folds a burst of keystrokes into a
        /// single full-document attribute pass instead of one per character.
        private func scheduleRender(_ textView: NSTextView) {
            pendingRender?.cancel()
            let render = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlighter.refresh(textView)
            }
            pendingRender = render
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: render)
        }

        /// Footer state is SwiftUI state; defer until AppKit finishes delivering
        /// the edit notification so panel creation doesn't mutate SwiftUI during
        /// view updates.
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
            guard !referenceViewManager.isInHelpView else { return }
            scheduleStatusUpdate(textView)
            // A caret move (or a note switch delivered through the selection
            // notification) can repoint the token the panel is completing;
            // re-derive it while the panel stays open.
            if completionPanel.isShown {
                syncCompletion(textView)
            }
        }

        /// Automatic punctuation substitutions are deliberately disabled so
        /// hyphens, flags, and pasted text never turn into unexpected Unicode.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !referenceViewManager.isInHelpView else { return true }
            recordUsage(affectedCharRange, replacement: replacementString, in: textView)
            if let replacement = replacementString, replacement == "\n" {
                let ns = textView.string as NSString
                var lineStart = 0, lineEnd = 0, contentsEnd = 0
                ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: affectedCharRange.location, length: 0))
                let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                // Only drive list continuation when the caret sits at the end
                // of the item's content; a mid-line return is a plain split.
                let caretInLine = affectedCharRange.location - lineStart
                guard caretInLine >= 0, caretInLine >= (line as NSString).length else { return true }
                switch IntentExecution.listContinuation(forLine: line) {
                case .continue(let marker):
                    textView.insertText("\n\(marker)", replacementRange: affectedCharRange)
                    return false
                case .endList:
                    // An empty item (`- `, `1. `) opening a list: return
                    // removes the marker so the next line is plain text.
                    let itemRange = NSRange(location: lineStart, length: (line as NSString).length)
                    if textView.shouldChangeText(in: itemRange, replacementString: "") {
                        textView.textStorage?.replaceCharacters(in: itemRange, with: "")
                        textView.didChangeText()
                    }
                    return false
                case nil:
                    return true
                }
            }
            return true
        }

        /// Return pressed: run any recognised intent on the caret's line
        /// before the newline lands.
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

        /// A settings-side font change lands here: restyle and re-render.
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


        /// Typing `=` after a full expression asks for the answer inline.
        /// Deferred and debounced so the rewrite never interrupts an ongoing
        /// statement: it only lands after typing quiets down on a complete
        /// expression, and appending more text cancels it.
        private func schedulePendingCalculation(_ textView: NSTextView) {
            deferredCalculationTask?.cancel()
            deferredCalculationTask = Task { [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, let textView,
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
        /// stored answers drifted are recomputed. Debounced, suppressed during undo.
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

            // Handle numeric recalculations
            applyCommits(IntentExecution.staleResultCommits(in: textView.string), to: textView)

            // Handle .time live updates
            updateTimeBoundaryTimer(textView)
        }

        /// Schedules or cancels the minute-boundary timer based on .time expression presence.
        private func updateTimeBoundaryTimer(_ textView: NSTextView?) {
            guard let textView else { return }

            let hasTimeExpressions = IntentExecution.containsTimeExpressions(textView.string)

            if hasTimeExpressions {
                // Schedule timer for next minute boundary if not already running
                if minuteBoundaryTimer == nil {
                    scheduleNextMinuteBoundary(textView)
                }
            } else {
                // Cancel timer if no .time expressions
                minuteBoundaryTimer?.cancel()
                minuteBoundaryTimer = nil
            }
        }

        /// Fires at the next wall-clock minute, then every minute after, so
        /// committed `.time` stamps stay current.
        private func scheduleNextMinuteBoundary(_ textView: NSTextView) {
            minuteBoundaryTimer?.cancel()

            let now = Date()
            let calendar = Calendar.current
            let nextMinute = calendar.nextDate(
                after: now,
                matching: DateComponents(second: 0, nanosecond: 0),
                matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(60)
            let timeInterval = max(0.05, nextMinute.timeIntervalSince(now))

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + timeInterval, repeating: .never)
            timer.setEventHandler { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.runTimeReevaluation(textView)
            }
            timer.resume()
            minuteBoundaryTimer = timer
        }

        /// Runs `.time` reevaluation and reschedules for the next minute.
        private func runTimeReevaluation(_ textView: NSTextView) {
            defer {
                if IntentExecution.containsTimeExpressions(textView.string) {
                    scheduleNextMinuteBoundary(textView)
                } else {
                    minuteBoundaryTimer?.cancel()
                    minuteBoundaryTimer = nil
                }
            }
            guard !autoRewritesSuppressed else { return }
            let timeCommits = IntentExecution.staleTimeCommits(in: textView.string)
            if !timeCommits.isEmpty {
                applyCommits(timeCommits, to: textView)
            }
        }

        /// Returns true when the intent consumed the return key.
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
            case .listTimers:
                referenceViewManager.enter(textView, content: TimerCenter.shared.report)
                return true
            case .listReminders:
                referenceViewManager.enter(textView, content: ReminderCenter.shared.report)
                return true
            case .listStopwatches:
                referenceViewManager.enter(textView, content: StopwatchCenter.shared.report)
                return true
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
                // Pull the `.new` command line out of the old note before the
                // active-note switch so the empties it leaves behind are clean.
                if let commandLineRange = caretLineRange(in: textView) {
                    textView.breakUndoCoalescing()
                    textView.insertText("", replacementRange: commandLineRange)
                }
                noteStore.create()
                return true
            case .clearNote:
                text.wrappedValue = ""
                return true
            case .deleteNote:
                // Remove the command line first, then delete the note
                if let commandLineRange = caretLineRange(in: textView) {
                    textView.breakUndoCoalescing()
                    textView.insertText("", replacementRange: commandLineRange)
                }
                noteStore.delete(noteStore.activeNote)
                text.wrappedValue = noteStore.activeNote.text
                return true
            case .showNoteSwitcher:
                showNoteSwitcher(textView)
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
            case .showStats:
                referenceViewManager.enter(textView, content: StatsCenter.shared.report)
                return true
            case .showVariables:
                referenceViewManager.enter(textView, content: IntentExecution.variablesReport(in: textView.string))
                return true
            case .quit:
                NSApplication.shared.terminate(nil)
                return true
            case .hide:
                textView.window?.miniaturize(nil)
                return true
            case .undo:
                textView.undoManager?.undo()
                return true
            case .redo:
                textView.undoManager?.redo()
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

        /// `.export`: send the whole note somewhere local.
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

        private func showNoteSwitcher(_ textView: NSTextView) {
            guard !referenceViewManager.isInHelpView, let window = textView.window else { return }
            let menu = NSMenu(title: "Note Switcher")
            let notes = noteStore.notes
            let header = NSMenuItem(title: "Notes (\(notes.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(string: header.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: PaneStyle.secondaryTextNSColor
            ])
            menu.addItem(header)
            menu.addItem(.separator())
            if notes.isEmpty {
                let empty = NSMenuItem(title: "No notes yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for note in notes {
                    let item = NSMenuItem(title: note.title, action: #selector(selectNoteItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = note.id
                    if note.id == noteStore.activeNoteID { item.state = .on }
                    menu.addItem(item)
                }
            }
            guard let contentView = window.contentView else { return }
            let anchor = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.maxY - min(contentView.bounds.height * 0.35, 220))
            menu.popUp(positioning: header, at: anchor, in: contentView)
        }

        @objc private func selectNoteItem(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            noteStore.activeNoteID = id
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

        /// Live footer: preview what return would do, offer answer for copying.
        private func updateFooterStatus(_ textView: NSTextView) {
            guard !referenceViewManager.isInHelpView else { return }
            guard let contentRange = caretLineRange(in: textView) else {
                status.wrappedValue = FooterStatus()
                return
            }
            let line = (textView.string as NSString).substring(with: contentRange)
            let words = textView.string.split(separator: /\s+/).count
            status.wrappedValue = FooterStatus(
                preview: IntentExecution.preview(forLine: line, in: textView.string) ?? "",
                answerToCopy: IntentExecution.answer(fromLine: line),
                wordCount: words)
        }


        /// Auto-open the completion panel once per `.partial` token.
        private func scheduleCompletion(_ textView: NSTextView) {
            completionTask?.cancel()
            let ns = textView.string as NSString
            let location = textView.selectedRange().location
            var start = location
            while start > 0 {
                let character = ns.character(at: start - 1)
                if character == unichar(" ") || character == unichar("\t") || character == unichar("\n") { break }
                start -= 1
            }
            let isDotCommand = isAutoReactCommandStart(in: ns, at: start, location: location)
            completionTask = Task { [weak self, weak textView] in
                if !isDotCommand { try? await Task.sleep(for: .milliseconds(240)) }
                guard !Task.isCancelled, let self, let textView else { return }
                guard !autoRewritesSuppressed,
                      textView.window?.firstResponder == textView,
                      textView.selectedRange().length == 0
                else { return }
                self.syncCompletion(textView)
            }
        }

        /// Open the panel now for the caret's dot-command token. Returns true
        /// when Tab was consumed by completion.
        func attemptTabCompletion() -> Bool {
            guard !referenceViewManager.isInHelpView else { return false }
            completionTask?.cancel()
            if completionPanel.isShown {
                completionPanel.tabComplete()
                return true
            }
            guard let textView = ownedTextView,
                  let tokenRange = completionTokenRange(in: textView),
                  tokenRange.length > 0
            else { return false }
            let token = (textView.string as NSString).substring(with: tokenRange)
            let candidates = IntentExecution.completionCandidates(
                for: token, usageCount: StatsCenter.shared.usageCount(for:))
            guard !candidates.isEmpty, suppressedTokenStart != tokenRange.location else { return false }
            bindCompletionAccept()
            completionPanel.show(
                in: textView,
                candidates: candidates,
                tokenStart: tokenRange.location,
                query: token)
            return true
        }

        /// Open the panel if the caret sits on a partial dot-command, refresh
        /// it while it's open, or dismiss when the token stopped matching.
        private func syncCompletion(_ textView: NSTextView) {
            guard !referenceViewManager.isInHelpView else { return }
            bindCompletionAccept()
            guard let tokenRange = completionTokenRange(in: textView), tokenRange.length > 1 else {
                completionPanel.dismiss()
                return
            }
            if let suppressed = suppressedTokenStart, suppressed != tokenRange.location {
                suppressedTokenStart = nil
            }
            if suppressedTokenStart == tokenRange.location { return }
            let token = (textView.string as NSString).substring(with: tokenRange)
            let candidates = IntentExecution.completionCandidates(
                for: token, usageCount: StatsCenter.shared.usageCount(for:))
            guard !candidates.isEmpty else {
                completionPanel.dismiss()
                return
            }
            if completionPanel.isShown {
                completionPanel.refilter(candidates: candidates, query: token)
            } else {
                completionPanel.show(
                    in: textView,
                    candidates: candidates,
                    tokenStart: tokenRange.location,
                    query: token)
            }
        }

        /// The unbroken token ending at the caret, or nil when none sits there.
        private func completionTokenRange(in textView: NSTextView) -> NSRange? {
            let ns = textView.string as NSString
            let location = textView.selectedRange().location
            guard location > 0, location <= ns.length else { return nil }
            var start = location
            while start > 0 {
                let character = ns.character(at: start - 1)
                if character == unichar(" ") || character == unichar("\t") || character == unichar("\n") {
                    break
                }
                start -= 1
            }
            guard isAutoReactCommandStart(in: ns, at: start, location: location) else { return nil }
            let commandStart = ns.character(at: start) == unichar("$") ? start + 2 : start
            return NSRange(location: commandStart, length: location - commandStart)
        }

        /// Finds a dot-command token either at the start of a normal token or
        /// immediately inside an interpolation such as `$(.sum 10 20)`.
        private func isAutoReactCommandStart(
            in ns: NSString,
            at start: Int,
            location: Int
        ) -> Bool {
            if start < location, ns.character(at: start) == unichar(".") {
                return true
            }
            return start + 2 < location
                && ns.character(at: start) == unichar("$")
                && ns.character(at: start + 1) == unichar("(")
                && ns.character(at: start + 2) == unichar(".")
        }

        private func bindCompletionAccept() {
            completionPanel.onAccept = { [weak self] entry, tokenStart, replacementLength, suppressFurther in
                self?.acceptCompletion(
                    entry,
                    tokenStart: tokenStart,
                    replacementLength: replacementLength,
                    suppressFurther: suppressFurther)
            }
        }

        /// Replace the typed partial with the chosen snippet, selecting its
        /// first placeholder. Counts toward `.stats` like real typing.
        private func acceptCompletion(
            _ entry: IntentExecution.DotCommand,
            tokenStart: Int,
            replacementLength: Int? = nil,
            suppressFurther: Bool = true
        ) {
            guard let textView = ownedTextView else { return }
            let caret = textView.selectedRange().location
            let textLength = (textView.string as NSString).length
            let tokenLength = replacementLength ?? (caret - tokenStart)
            guard tokenStart >= 0,
                  tokenLength >= 0,
                  tokenStart + tokenLength <= textLength
            else { return }
            textView.breakUndoCoalescing()
            textView.insertText(entry.snippet, replacementRange: NSRange(location: tokenStart, length: tokenLength))
            StatsCenter.shared.record(typed: (entry.snippet as NSString).length, deleted: tokenLength)
            StatsCenter.shared.record(command: entry.name)
            if suppressFurther { suppressedTokenStart = tokenStart }
            if let (range, _) = IntentExecution.placeholderRange(in: entry.snippet) {
                textView.setSelectedRange(NSRange(location: tokenStart + range.location, length: range.length))
            }
        }

        /// Applies commits bottom-up so earlier ranges survive later insertions.
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

        private func caretLineRange(in textView: NSTextView) -> NSRange? {
            IntentExecution.caretLineRange(in: textView.string, selection: textView.selectedRange())
        }

        /// Counts one edit's inserted and removed characters toward `.stats`.
        /// Whole-document replacements are programmatic reloads (`.replace`'s
        /// main pass, note switching), not the user typing, so they're skipped.
        private func recordUsage(_ range: NSRange, replacement: String?, in textView: NSTextView) {
            let length = (textView.string as NSString).length
            guard range.length < length || length == 0 else { return }
            let typed = replacement?.count ?? 0
            let deleted = range.length
            guard typed > 0 || deleted > 0 else { return }
            StatsCenter.shared.record(typed: typed, deleted: deleted)
        }
    }
}
