import AppKit
import Combine
import SwiftUI

// MARK: - Completion list

/// The intellisense list backing the completion panel, keyboard-driven.
@MainActor
final class CommandCompletionModel: ObservableObject {
    @Published var entries: [IntentExecution.DotCommand] = []
    @Published var selection = 0
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
                        CommandCompletionRow(entry: entry, isSelected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                onPick?(index)
                            }
                            .id(index)
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

    private static func height(for entries: [IntentExecution.DotCommand]) -> CGFloat {
        min(CGFloat(entries.count) * 26 + 10, 240)
    }
}

struct CommandCompletionRow: View {
    let entry: IntentExecution.DotCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.name)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.description)
                .font(.system(.caption))
                .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Panel

/// A caret-anchored, keyboard-driven command palette for dot-commands. Hosted
/// as a child window so the pane keeps key focus while the list stays above.
@MainActor
final class CommandCompletionPanel {
    var onAccept: ((IntentExecution.DotCommand, Int) -> Void)?

    private let model = CommandCompletionModel()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: Any?
    private weak var textView: NSTextView?
    private var entries: [IntentExecution.DotCommand] = []
    private var tokenStart = 0

    var isShown: Bool { panel != nil }

    func show(in textView: NSTextView, candidates: [IntentExecution.DotCommand], tokenStart: Int) {
        guard !candidates.isEmpty, let window = textView.window else { return }
        dismiss()
        self.textView = textView
        self.entries = candidates
        self.tokenStart = tokenStart
        model.entries = candidates
        model.selection = 0

        let size = NSSize(width: 360, height: min(CGFloat(candidates.count) * 26 + 8, 240))
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

    func refilter(candidates: [IntentExecution.DotCommand]) {
        guard let panel, !candidates.isEmpty else { dismiss(); return }
        entries = candidates
        model.entries = candidates
        model.selection = min(model.selection, candidates.count - 1)
        let size = NSSize(width: panel.frame.width, height: min(CGFloat(candidates.count) * 26 + 8, 240))
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        model.selection = max(0, min(entries.count - 1, model.selection + delta))
    }

    func acceptSelected() {
        guard !entries.isEmpty else { dismiss(); return }
        pick(model.selection)
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
    }

    private func pick(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        dismiss()
        onAccept?(entry, tokenStart)
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
                case 36, 76, 48: self.acceptSelected(); return true
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