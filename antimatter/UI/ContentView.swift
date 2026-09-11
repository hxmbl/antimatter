import SwiftUI
import AppKit

struct ContentView: View {
    /// The pane's store. The primary window uses the shared store; ⌘N
    /// windows pass their own scratchpad store here.
    @StateObject private var noteStore: NoteStore
    // Declared so a Settings-side change re-renders (and re-styles) the editor.
    @AppStorage("fontSize") private var fontSizeObservation = 15
    @AppStorage("pane.cornerRadius") private var cornerRadiusObservation = 18.0
    @AppStorage("pane.maxWidth") private var maxWidthObservation = 600.0
    @AppStorage("pane.usesBlur") private var usesBlurObservation = true
    @AppStorage("pane.tintOpacity") private var tintOpacityObservation = 0.10
    @AppStorage("pane.windowAlpha") private var windowAlphaObservation = 1.0
    @AppStorage("pane.floats") private var floatsObservation = true
    @AppStorage("pane.hidesOnEscape") private var hidesOnEscapeObservation = true
    @AppStorage("pane.themeID") private var themeIDObservation = "default"
    @AppStorage("appearance") private var appearanceObservation = "system"
    @State private var footer = FooterStatus()
    @State private var sidebarOpen = false

    init(noteStore: NoteStore = NoteStore.shared) {
        _noteStore = StateObject(wrappedValue: noteStore)
    }

    /// Dock mode runs as a regular window whose own title bar frames the
    /// content, so the theme fills the whole window instead of floating as a
    /// rounded card over a transparent gap. The floating modes keep the
    /// padded card so the desktop shows around it.
    private var isDock: Bool { PaneStyle.displayMode == .dock }
    private var topInset: CGFloat { isDock ? 0 : PaneStyle.titleBarInset }
    private var horizontalInset: CGFloat { isDock ? 0 : PaneStyle.padding }
    private var bottomInset: CGFloat { isDock ? 0 : PaneStyle.padding + PaneStyle.footerHeight }

    var body: some View {
            PaneEditor(text: noteStore.activeText, status: $footer, noteStore: noteStore)
            .onTapGesture {
                sidebarOpen = false
            }
            .padding(.top, topInset)
            .padding(.leading, horizontalInset)
            .padding(.trailing, horizontalInset)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: PaneStyle.maxWidth, maxHeight: PaneStyle.maxHeight)
            .background { PaneBackground() }
            .clipShape(RoundedRectangle(cornerRadius: PaneStyle.cornerRadius, style: .continuous))
            .overlay(alignment: .topTrailing) { CaptureStrip().padding(.trailing, 10) }
            .overlay(alignment: .bottomLeading) { SaveErrorHint(error: noteStore.saveError, token: noteStore.saveErrorToken).padding(.leading, PaneStyle.padding) }
            .overlay(alignment: .bottom) {
                PaneFooter(status: footer, sidebarOpen: $sidebarOpen)
                    .padding(.horizontal, PaneStyle.padding)
                    .padding(.bottom, 7)
            }
            .overlay(WindowDragEdge())
            .overlay(alignment: .leading) {
                if sidebarOpen {
                    SidebarView(store: noteStore, isOpen: $sidebarOpen)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.15), value: sidebarOpen)
                }
            }
            .background(WindowConfigurator())
        .background(HotKeyWindowBridge())
            .gesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .local)
                    .onEnded { value in
                        if value.translation.width < -30 {
                            noteStore.cycleNote(direction: -1)
                        } else if value.translation.width > 30 {
                            noteStore.cycleNote(direction: 1)
                        }
                    }
            )
            .onAppear {
                if !UserDefaults.standard.bool(forKey: PaneStyle.didWelcomeKey) {
                    UserDefaults.standard.set(true, forKey: PaneStyle.didWelcomeKey)
                    NoticeCenter.shared.show("Antimatter — type `.help` for every command")
                }
            }
            // Debounced saves leave a small window where quitting would lose
            // the last keystrokes; flushing here closes it.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                // Any window closing posts here; only a pane's own file matters.
                let identifier = (note.object as? NSWindow)?.identifier?.rawValue
                guard identifier?.hasPrefix(PaneStyle.windowIdentifier) == true else { return }
                noteStore.flush()
            }
            // Settings that live on the NSWindow itself (level, fade, corner,
            // size clamp) are re-applied here; the rest take effect through
            // SwiftUI re-rendering.
            .onChange(of: cornerRadiusObservation) { _, _ in PaneWindowStyler.applyToPane() }
            .onChange(of: maxWidthObservation) { _, _ in PaneWindowStyler.applyToPane() }
            .onChange(of: windowAlphaObservation) { _, _ in PaneWindowStyler.applyToPane() }
            .onChange(of: floatsObservation) { _, _ in PaneWindowStyler.applyToPane() }
            .onChange(of: themeIDObservation) { _, _ in PaneWindowStyler.applyToPane() }
            .onChange(of: appearanceObservation) { _, _ in PaneWindowStyler.applyToPane() }
    }
}

/// Captures SwiftUI's `openWindow` action so the global hot key can
/// recreate the pane after it has been closed.
private struct HotKeyWindowBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { PaneHotKey.shared.openWindow = { openWindow(id: PaneStyle.windowIdentifier) } }
    }
}

/// Allows window dragging from any edge even when at max size. The drag
/// gesture must claim only the thin edge strip: `contentShape` is applied
/// *before* the `.frame(maxWidth/maxHeight: .infinity)` expansion so the
/// hit shape stays lip-sized, otherwise the invisible full-pane frame
/// swallows every click, drag, and scroll meant for the text view.
private struct WindowDragEdge: View {
    private let lip = PaneStyle.windowDragLip

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: lip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .gesture(windowDragGesture())
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: lip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .gesture(windowDragGesture())
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: lip, height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .gesture(windowDragGesture())
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: lip, height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .gesture(windowDragGesture())
            }
        }
    }

    private func windowDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if let window = NSApp.keyWindow {
                    let event = NSApp.currentEvent ?? NSEvent()
                    window.performDrag(with: event)
                }
            }
    }
}

/// Floating chips for running timers and the active paste stream,
/// top-right of the pane.
private struct CaptureStrip: View {
    @ObservedObject private var center = TimerCenter.shared
    @ObservedObject private var swatches = StopwatchCenter.shared
    @ObservedObject private var stream = PasteStream.shared
    @ObservedObject private var notices = NoticeCenter.shared
    @ObservedObject private var reminders = ReminderCenter.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !center.timers.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(center.timers) { timer in
                            TimerChip(timer: timer, now: context.date) {
                                center.dismiss(timer.id)
                            }
                        }
                    }
                }
            }
            if !swatches.stopwatches.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(swatches.stopwatches) { stopwatch in
                            StopwatchChip(
                                stopwatch: stopwatch,
                                now: context.date,
                                onStop: { swatches.stop(stopwatch.id) },
                                onDismiss: { swatches.dismiss(stopwatch.id) }
                            )
                        }
                    }
                }
            }
            if !reminders.reminders.isEmpty {
                ForEach(reminders.reminders) { reminder in
                    ReminderChip(reminder: reminder) {
                        reminders.dismiss(reminder.id)
                    }
                }
            }
            if stream.isStreaming {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 9, weight: .medium))
                    Text("paste stream")
                    Button(action: stream.stopStreaming) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: 0.5))
            }
            if let notice = notices.notice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9, weight: .medium))
                    Text(notice)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: 0.5))
            }
        }
        .padding(.top, 0)
    }
}

private struct TimerChip: View {
    let timer: ActiveTimer
    let now: Date
    let onDismiss: () -> Void

    private var remaining: TimeInterval {
        max(0, timer.endDate.timeIntervalSince(now))
    }

    private var isDone: Bool {
        remaining == 0
    }

    var body: some View {
        HStack(spacing: 6) {
            if let name = timer.name {
                Text(name)
                    .lineLimit(1)
                    .opacity(isDone ? 0.5 : 1)
            }
            if !timer.label.isEmpty {
                Text(timer.label)
                    .lineLimit(1)
                    .opacity(isDone ? 0.5 : 1)
            }
            Text(isDone ? "done" : TimerCenter.format(remaining))
                .monospacedDigit()
                .foregroundStyle(isDone ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: 0.5))
    }
}

/// A stopwatch counting up, top-right of the pane. Running ones tick and
/// can be stopped (freezing the reading); stopped ones stay until dismissed.
private struct StopwatchChip: View {
    let stopwatch: ActiveStopwatch
    let now: Date
    let onStop: () -> Void
    let onDismiss: () -> Void

    private var isRunning: Bool {
        stopwatch.stoppedAt == nil
    }

    private var elapsed: TimeInterval {
        if let stoppedAt = stopwatch.stoppedAt {
            return stoppedAt.timeIntervalSince(stopwatch.startedAt)
        }
        return now.timeIntervalSince(stopwatch.startedAt)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "stopwatch")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isRunning ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            if !stopwatch.label.isEmpty {
                Text(stopwatch.label)
                    .lineLimit(1)
            }
            Text(StopwatchCenter.format(elapsed))
                .monospacedDigit()
                .foregroundStyle(isRunning ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: 0.5))
    }
}

/// A reminder waiting to ring, top-right of the pane.
private struct ReminderChip: View {
    let reminder: ActiveReminder
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell")
                .font(.system(size: 9, weight: .medium))
            Text(reminder.message)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(ReminderCenter.format(reminder.date.timeIntervalSinceNow))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: 0.5))
    }
}

/// Transient notice when a flush failed; the store clears itself after a
/// few seconds, so this simply renders whatever is current.
private struct SaveErrorHint: View {
    let error: Error?
    let token: Int

    var body: some View {
        Group {
            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 10, weight: .medium))
                    Text("Couldn't save — \(error.localizedDescription)")
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: 0.5))
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: token)
    }
}

/// Quiet status strip under the editor: a live "what ⏎ will do" preview,
/// one-tap copy of a committed answer, and the pane's shortcuts.
private struct PaneFooter: View {
    let status: FooterStatus
    @Binding var sidebarOpen: Bool

    private var gradeLabel: String {
        guard let ease = status.readingEase else { return "Grade 0" }
        let grade: Int
        switch ease {
        case 90...: grade = 5
        case 80..<90: grade = 6
        case 70..<80: grade = 7
        case 60..<70: grade = 8
        case 50..<60: grade = 10
        case 30..<50: grade = 13
        default: grade = 17
        }
        return "Grade \(grade)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let answer = status.answerToCopy {
                    Button {
                        copy(answer)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9, weight: .medium))
                            Text("copy \(answer)")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                } else if !status.preview.isEmpty {
                    Text(status.preview)
                } else {
                    Text(".help for commands")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer()
            if PaneStyle.showWordCount, status.charCount > 0 {
                Text("\(status.wordCount) words · \(status.charCount) chars · \(gradeLabel)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Text("⌘F find · Esc hide")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button(action: { sidebarOpen.toggle() }) {
                Image(systemName: sidebarOpen ? "rectangle.leadinghalf.inset.filled.arrow.leading" : "line.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: PaneStyle.footerHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.15), value: status)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        NoticeCenter.shared.show("Answer copied — \(value)")
    }
}

#Preview {
    ContentView()
}
