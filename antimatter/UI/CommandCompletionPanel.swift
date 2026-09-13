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
    /// Inserts a candidate. The last flag is true for Return/click (panel
    /// closes) and false for Tab-cycling, which must stay reopenable.
    var onAccept: ((IntentExecution.DotCommand, Int, Int, Bool) -> Void)?

    private let model = CommandCompletionModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: Any?
    private weak var textView: NSTextView?
    private var entries: [CompletionEntry] = []
    private var tokenStart = 0
    private var replacementLength = 0

    var isShown: Bool { panel != nil }

    func show(in textView: NSTextView, candidates: [IntentExecution.DotCommand], tokenStart: Int, query: String) {
        guard !candidates.isEmpty, let window = textView.window else { return }
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
        startMonitoring()
    }

    func refilter(candidates: [IntentExecution.DotCommand], query: String) {
        guard let panel, !candidates.isEmpty else { dismiss(); return }
        entries = Self.buildEntries(from: candidates)
        replacementLength = (query as NSString).length
        model.entries = entries
        model.query = query
        model.selection = Self.nextSelectableIndex(from: entries, startingAt: model.selection)
        let size = NSSize(width: panel.frame.width, height: Self.height(for: entries))
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let selectableIndices = Self.selectableIndices(in: entries)
        guard let current = selectableIndices.firstIndex(of: model.selection) else { return }
        let next = max(0, min(selectableIndices.count - 1, current + delta))
        model.selection = selectableIndices[next]
    }

    func acceptSelected() {
        guard !entries.isEmpty else { dismiss(); return }
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

    /// Inserts the current candidate while leaving the panel open so the next
    /// Tab replaces that insertion with the next candidate.
    func tabComplete() {
        guard let index = Self.selectableIndices(in: entries).first(where: { $0 == model.selection }),
              let command = entries[index].command
        else { dismiss(); return }

        onAccept?(command, tokenStart, replacementLength, false)
        replacementLength = (command.snippet as NSString).length

        let selectable = Self.selectableIndices(in: entries)
        guard let position = selectable.firstIndex(of: index), !selectable.isEmpty else { return }
        model.selection = selectable[(position + 1) % selectable.count]
    }

    func dismiss() {
        dismissMonitoring()
        if let panel {
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
        dismiss()
        onAccept?(command, tokenStart, replacementLength, true)
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
        }
    }

    private func dismissMonitoring() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        mouseMonitor = nil
        resignObserver = nil
    }
}
