import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var store = ScratchStore.shared
    // Declared so a Settings-side change re-renders (and re-styles) the editor.
    @AppStorage("fontSize") private var fontSizeObservation = 15
    @State private var footer = FooterStatus()

    var body: some View {
        ZStack(alignment: .top) {
            PaneEditor(text: $store.text, status: $footer)
                .padding(.top, PaneStyle.titleBarInset)
                .padding(.leading, PaneStyle.padding)
                .padding(.trailing, PaneStyle.padding)
                .padding(.bottom, PaneStyle.padding + PaneStyle.footerHeight)
                .frame(maxWidth: PaneStyle.maxWidth, maxHeight: PaneStyle.maxHeight)
                .background { PaneBackground() }
                .clipShape(RoundedRectangle(cornerRadius: PaneStyle.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PaneStyle.cornerRadius, style: .continuous)
                        .strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: PaneStyle.borderWidth)
                }
                .overlay(alignment: .topTrailing) { CaptureStrip().padding(.trailing, 10) }
                .overlay(alignment: .bottomLeading) { SaveErrorHint(error: store.saveError, token: store.saveErrorToken).padding(.leading, PaneStyle.padding) }
                .overlay(alignment: .bottom) {
                    PaneFooter(status: footer)
                        .padding(.horizontal, PaneStyle.padding)
                        .padding(.bottom, 7)
                }
                .overlay(WindowDragEdge())
            TitleBarBackground()
        }
        .background(WindowConfigurator())
        .background(HotKeyWindowBridge())
            .onChange(of: store.text) { _, _ in store.textDidChange() }
            .onAppear {
                if !UserDefaults.standard.bool(forKey: PaneStyle.didWelcomeKey) {
                    UserDefaults.standard.set(true, forKey: PaneStyle.didWelcomeKey)
                    NoticeCenter.shared.show("Antimatter — type `.help` for every command")
                }
            }
            // Debounced saves leave a small window where quitting would lose
            // the last keystrokes; flushing here closes it.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                // Any window closing posts here; only the pane's own file matters.
                guard (note.object as? NSWindow)?.identifier?.rawValue == PaneStyle.windowIdentifier else { return }
                store.flush()
            }
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

/// Allows window dragging from any edge even when at max size.
private struct WindowDragEdge: View {
    private let lip = PaneStyle.windowDragLip

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .frame(width: geo.size.width, height: lip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(windowDragGesture())
                Color.clear
                    .frame(width: geo.size.width, height: lip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(windowDragGesture())
                Color.clear
                    .frame(width: lip, height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(windowDragGesture())
                Color.clear
                    .frame(width: lip, height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
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

/// Title bar background with less transparency than content area.
private struct TitleBarBackground: View {
    var body: some View {
        VisualEffectBackground(material: .headerView, blendingMode: .withinWindow)
            .frame(height: PaneStyle.titleBarInset)
            .clipShape(RoundedRectangle(cornerRadius: PaneStyle.cornerRadius, style: .continuous))
            .allowsHitTesting(false)
    }
}

/// Floating chips for running timers and the active paste stream,
/// top-right of the pane.
private struct CaptureStrip: View {
    @ObservedObject private var center = TimerCenter.shared
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
        .padding(.top, PaneStyle.titleBarInset - 8)
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
            Text("⌘F find · Esc hide")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
