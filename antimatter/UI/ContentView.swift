import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var store = ScratchStore.shared
    // Declared so a Settings-side change re-renders (and re-styles) the editor.
    @AppStorage("fontSize") private var fontSizeObservation = 15

    var body: some View {
        PaneEditor(text: $store.text)
            .padding(.top, PaneStyle.titleBarInset)
            .padding(.leading, PaneStyle.padding)
            .padding(.trailing, PaneStyle.padding)
            .padding(.bottom, PaneStyle.padding)
            .frame(maxWidth: PaneStyle.maxWidth, maxHeight: PaneStyle.maxHeight)
            .background { PaneBackground() }
            .clipShape(RoundedRectangle(cornerRadius: PaneStyle.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PaneStyle.cornerRadius, style: .continuous)
                    .strokeBorder(PaneStyle.border.opacity(PaneStyle.borderOpacity), lineWidth: PaneStyle.borderWidth)
            }
            .overlay(alignment: .topTrailing) { CaptureStrip().padding(.trailing, 10) }
            .overlay(alignment: .bottomLeading) { SaveErrorHint(error: store.saveError).padding(.leading, PaneStyle.padding) }
            .background(WindowConfigurator())
            .background(HotKeyWindowBridge())
            .onChange(of: store.text) { _, _ in store.textDidChange() }
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

/// Floating chips for running timers and the active paste stream,
/// top-right of the pane.
private struct CaptureStrip: View {
    @ObservedObject private var center = TimerCenter.shared
    @ObservedObject private var stream = PasteStream.shared

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

/// Transient notice when a flush failed; the store clears itself after a
/// few seconds, so this simply renders whatever is current.
private struct SaveErrorHint: View {
    let error: Error?

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
        .animation(.easeInOut(duration: 0.2), value: error as NSError?)
    }
}

#Preview {
    ContentView()
}
