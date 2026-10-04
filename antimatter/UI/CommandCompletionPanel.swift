import AppKit
import Combine
import SwiftUI

// MARK: - Completion list

/// The AutoReact list backing the completion panel, keyboard-driven.
@MainActor
final class CommandCompletionModel: ObservableObject {
    @Published var entries: [CompletionEntry] = []
    @Published var selection = 0
    @Published var query = ""
}

/// A flat list item: either a selectable command or a non-selectable section header.
enum CompletionEntry: Equatable {
    case command(IntentExecution.DotCommand)
    case sectionHeader(String)

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }

    var command: IntentExecution.DotCommand? {
        if case .command(let command) = self { return command }
        return nil
    }
}

struct CommandCompletionListView: View {
    @ObservedObject var model: CommandCompletionModel
    var onPick: ((Int) -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.entries.indices, id: \.self) { index in
                        let entry = model.entries[index]
                        switch entry {
                        case .command(let command):
                            CommandCompletionRow(entry: command, query: model.query, isSelected: index == model.selection)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selection = index
                                    onPick?(index)
                                }
                                .id(index)
                        case .sectionHeader(let title):
                            SectionHeaderView(title: title)
                                .id(index)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selection) { _, new in
                withAnimation(nil) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .background(VisualEffectBackground(
            material: PaneStyle.material,
            blendingMode: PaneStyle.blending,
            cornerRadius: 8
        ))
        .frame(width: 360, height: Self.height(for: model.entries))
    }

    private static func height(for entries: [CompletionEntry]) -> CGFloat {
        let commandCount = entries.filter { $0.isCommand }.count
        return min(CGFloat(commandCount) * 26 + 10 + CGFloat(entries.count - commandCount) * 20, 260)
    }
}

struct SectionHeaderView: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .background(Color.primary.opacity(0.06))
    }
}

struct CommandCompletionRow: View {
    let entry: IntentExecution.DotCommand
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            highlightedText(entry.name, query: query)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            highlightedText(entry.description, query: query)
                .font(.system(.caption))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        let loweredQuery = String(query.dropFirst(IntentParser.commandPrefix.count)).lowercased()
        let matchColor: Color = isSelected ? .white : .accentColor
        let restColor: Color = isSelected ? .white : .primary
        guard !loweredQuery.isEmpty else {
            return Text(text).foregroundStyle(restColor)
        }

        let characters = Array(text.lowercased())
        var matched = Set<Int>()
        var searchStart = 0
        for character in loweredQuery {
            guard let offset = characters[searchStart...].firstIndex(of: character) else { break }
            matched.insert(offset)
            searchStart = offset + 1
        }

        var attributed = AttributedString()
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = matchColor
            } else {
                piece.foregroundColor = restColor
            }
            attributed.append(piece)
        }
        return Text(attributed)
    }
}

// MARK: - Panel

/// A caret-anchored, keyboard-driven command palette for dot-commands. Hosted
/// as a child window so the pane keeps key focus while the list stays above.
@MainActor
final class CommandCompletionPanel {

    /// How many completion panels are on screen, across every pane.
    ///
    /// A global Escape monitor has to be able to tell "the note is idle" from
    /// "the completion list is up". Whichever order AppKit calls local event
    /// monitors in, taking Escape there would otherwise steal the key from the
    /// list's own dismiss.
    /// `nonisolated(unsafe)` because `deinit` is nonisolated and still has to
    /// keep the count honest. Every mutation happens on the main thread.
    nonisolated(unsafe) private static var openPanelStorage = 0

    static var openPanelCount: Int { openPanelStorage }

    /// True while any pane is showing a completion list.
    static var isAnyPanelOpen: Bool { openPanelStorage > 0 }

    /// Inserts a candidate. The last flag is true for Return/click (panel
    /// closes) and false for Tab-cycling, which must stay reopenable.
    var onAccept: ((IntentExecution.DotCommand, Int, Int, Bool) -> Void)?

    private let model = CommandCompletionModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: Any?
    private var orderOutObserver: Any?
    private var minimizeObserver: Any?
    private weak var textView: NSTextView?
    private var entries: [CompletionEntry] = []
    private var tokenStart = 0
    private var replacementLength = 0
    /// True while `tabComplete()` drives an insertion. The insert
    /// synchronously re-enters this panel through `textDidChange` →
    /// `syncCompletion`, and at that moment the caret sits mid-snippet (after a
    /// space, or inside a `<placeholder>`), so no completion token matches and
    /// the caller asks to dismiss — or refilters against a token the user never
    /// typed. Both would kill Tab cycling after a single press.
    private var isTabCycling = false

    var isShown: Bool { panel != nil }

    func show(in textView: NSTextView, candidates: [IntentExecution.DotCommand], tokenStart: Int, query: String) {
        guard !candidates.isEmpty, let window = textView.window else { return }
        guard !isTabCycling else { return }
        dismiss()
        self.textView = textView
        self.entries = Self.buildEntries(from: candidates)
        self.tokenStart = tokenStart
        self.replacementLength = (query as NSString).length
        model.entries = self.entries
        model.query = query
        model.selection = Self.nextSelectableIndex(from: self.entries, startingAt: 0)

        let size = NSSize(width: 360, height: Self.height(for: self.entries))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: CommandCompletionListView(model: model, onPick: pick))
        panel.setFrame(placedFrame(for: textView, tokenStart: tokenStart, size: size), display: true)
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        Self.openPanelStorage += 1
        startMonitoring()
    }

    func refilter(candidates: [IntentExecution.DotCommand], query: String) {
        guard !isTabCycling else { return }
        guard let panel, !candidates.isEmpty else { dismiss(); return }
        entries = Self.buildEntries(from: candidates)
        replacementLength = (query as NSString).length
        model.entries = entries
        model.query = query
        model.selection = Self.nextSelectableIndex(from: entries, startingAt: model.selection)
        let size = NSSize(width: panel.frame.width, height: Self.height(for: entries))
        if let textView {
            // Re-place rather than only resizing: a taller list would
            // otherwise hang off the bottom of the screen.
            panel.setFrame(placedFrame(for: textView, tokenStart: tokenStart, size: size), display: true)
        } else {
            var frame = panel.frame
            frame.size = size
            frame.origin.y = max(frame.origin.y, panel.screen?.visibleFrame.minY ?? frame.origin.y)
            panel.setFrame(frame, display: true)
        }
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let selectableIndices = Self.selectableIndices(in: entries)
        guard let current = selectableIndices.firstIndex(of: model.selection) else { return }
        let next = max(0, min(selectableIndices.count - 1, current + delta))
        model.selection = selectableIndices[next]
    }

    func acceptSelected() {
        guard entries.indices.contains(model.selection) else { dismiss(); return }
        if entries[model.selection].isCommand {
            pick(model.selection)
        } else {
            // Selection landed on a header — jump to the first selectable entry.
            let selectable = Self.selectableIndices(in: entries)
            guard let first = selectable.first else { dismiss(); return }
            model.selection = first
            pick(first)
        }
    }

    deinit {
        // Keep the global open-panel census honest and unhook the event
        // monitors even if a pane is torn down mid-cycle without `dismiss()`
        // running. A leaked `keyDown` monitor stays in the process-wide event
        // pipeline forever.
        Self.removeMonitors(key: keyMonitor, mouse: mouseMonitor,
                            resign: resignObserver, orderOut: orderOutObserver)
        if let minimizeObserver {
            NotificationCenter.default.removeObserver(minimizeObserver)
        }
        if panel != nil { Self.openPanelStorage -= 1 }
    }

    /// `nonisolated` so `deinit` can reach it; `NSEvent`/`NotificationCenter`
    /// removal is safe from any thread.
    private nonisolated static func removeMonitors(
        key: Any?, mouse: Any?, resign: Any?, orderOut: Any?
    ) {
        if let key { NSEvent.removeMonitor(key) }
        if let mouse { NSEvent.removeMonitor(mouse) }
        if let resign { NotificationCenter.default.removeObserver(resign) }
        if let orderOut { NotificationCenter.default.removeObserver(orderOut) }
    }

    /// Inserts the current candidate while leaving the panel open so the next
    /// Tab replaces that insertion with the next candidate.
    func tabComplete() {
        guard onAccept != nil else { dismiss(); return }
        let selectable = Self.selectableIndices(in: entries)
        guard let index = selectable.firstIndex(of: model.selection) ?? selectable.first,
              let command = entries[index].command
        else { dismiss(); return }

        // Highlight the *next* row before the insertion, while `entries` is
        // still intact. The insert below re-enters this panel through
        // `textDidChange` → `syncCompletion`, and the caret is then sitting
        // after the inserted text, so the original order (insert, then advance)
        // found an empty `entries` and dropped the advance: Tab worked once and
        // the second Tab typed a literal tab.
        model.selection = selectable[(index + 1) % selectable.count]

        let previousReplacementLength = replacementLength
        replacementLength = (command.snippet as NSString).length
        isTabCycling = true
        defer { isTabCycling = false }
        onAccept?(command, tokenStart, previousReplacementLength, false)
    }

    func dismiss() {
        // A Tab-driven insertion asks to dismiss from inside `onAccept`. Honour
        // that and the panel disappears the moment Tab is pressed once, which is
        // precisely what the cycling is supposed to avoid.
        guard !isTabCycling else { return }
        dismissMonitoring()
        if let panel {
            Self.openPanelStorage -= 1
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        textView = nil
        entries = []
        tokenStart = 0
        replacementLength = 0
        model.entries = []
        model.query = ""
        model.selection = 0
    }

    private func pick(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        guard let command = entries[index].command else { return }
        // Read the replacement window *before* dismissing: `dismiss()` resets
        // `tokenStart`/`replacementLength` to 0, and passing those on meant
        // every click inserted the snippet at the top of the note, replacing
        // nothing.
        let start = tokenStart
        let length = replacementLength
        dismiss()
        onAccept?(command, start, length, true)
    }

    private static func height(for entries: [CompletionEntry]) -> CGFloat {
        let commandCount = entries.filter(\.isCommand).count
        let headerCount = entries.count - commandCount
        return min(CGFloat(commandCount) * 26 + 10 + CGFloat(headerCount) * 20, 260)
    }

    private static func buildEntries(from commands: [IntentExecution.DotCommand]) -> [CompletionEntry] {
        var entries: [CompletionEntry] = []
        var lastCategory: IntentExecution.DotCommandCategory? = nil
        for command in commands {
            if command.category != lastCategory {
                entries.append(.sectionHeader(command.category.rawValue))
                lastCategory = command.category
            }
            entries.append(.command(command))
        }
        return entries
    }

    private static func selectableIndices(in entries: [CompletionEntry]) -> [Int] {
        entries.enumerated().compactMap { index, entry in
            entry.isCommand ? index : nil
        }
    }

    private static func nextSelectableIndex(from entries: [CompletionEntry], startingAt index: Int) -> Int {
        let selectable = selectableIndices(in: entries)
        guard let next = selectable.first(where: { $0 >= index }) else {
            return selectable.first ?? 0
        }
        return next
    }

    private func placedFrame(
        for textView: NSTextView,
        tokenStart: Int,
        size: NSSize
    ) -> NSRect {
        guard let window = textView.window, let screen = window.screen
                ?? NSScreen.main
        else { return NSRect(origin: .zero, size: size) }
        let caret = caretScreenRect(in: textView, at: tokenStart)
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 4)
        if origin.y < screen.visibleFrame.minY {
            origin.y = caret.maxY + 4
        }
        origin.x = max(screen.visibleFrame.minX + 8, min(origin.x, screen.visibleFrame.maxX - size.width - 8))
        return NSRect(origin: origin, size: size)
    }

    private func caretScreenRect(in textView: NSTextView, at index: Int) -> NSRect {
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return NSRect(x: 0, y: 0, width: 8, height: 16)
        }
        let glyphRange = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 0), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        if let window = textView.window {
            rect = textView.convert(rect, to: nil)
            return window.convertToScreen(rect)
        }
        return rect
    }

    // MARK: Event plumbing

    private func startMonitoring() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                switch keyCode {
                case 125: self.moveSelection(1); return true
                case 126: self.moveSelection(-1); return true
                case 36, 76: self.acceptSelected(); return true
                case 48: self.tabComplete(); return true
                case 53: self.dismiss(); return true
                default: return false
                }
            }
            return handled ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return false }
                if windowNumber != panel.windowNumber { self.dismiss() }
                return false
            }
            return handled ? nil : event
        }
        if let window = textView?.window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
            // The panel is a *child* window, so it is hidden whenever the pane
            // is — but hidden, not torn down. Esc and ⌘. both dismiss, but the
            // global hot key and `WindowConfigurator`'s non-dock `orderOut` do
            // not, and a panel that survives those comes back VISIBLE with stale
            // rows the next time the pane is shown.
            //
            // AppKit posts no notification for `orderOut` (verified against the
            // SDK: only didBecomeKey/didResignKey/didMiniaturize/willClose and
            // friends exist), so close and minimize are covered by observers and
            // the `orderOut` case is covered by `paneIsVisible`, which the
            // coordinator consults before re-showing anything.
            orderOutObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
            minimizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    /// True when the pane this panel is attached to is on screen. AppKit gives no
    /// order-out notification, so this is how a panel that outlived a
    /// hide-the-pane gesture gets torn down instead of reappearing stale.
    var paneIsVisible: Bool {
        textView?.window?.isVisible ?? false
    }

    private func dismissMonitoring() {
        Self.removeMonitors(key: keyMonitor, mouse: mouseMonitor,
                            resign: resignObserver, orderOut: orderOutObserver)
        orderOutObserver = nil
        if let minimizeObserver {
            NotificationCenter.default.removeObserver(minimizeObserver)
        }
        minimizeObserver = nil
    }
}
