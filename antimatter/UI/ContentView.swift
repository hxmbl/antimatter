import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var store = ScratchStore.shared

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
            .overlay(alignment: .topTrailing) { TimerStrip().padding(.trailing, 10) }
            .background(WindowConfigurator())
            .background(HotKeyWindowBridge())
            .onChange(of: store.text) { _, _ in store.textDidChange() }
            // Debounced saves leave a small window where quitting would lose
            // the last keystrokes; flushing here closes it.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                store.flush()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
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

/// Floating countdown chips for running timers, top-right of the pane.
private struct TimerStrip: View {
    @ObservedObject private var center = TimerCenter.shared

    var body: some View {
        Group {
            if center.timers.isEmpty {
                Color.clear.frame(width: 0, height: 0)
            } else {
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
            Text(isDone ? "done" : Self.format(remaining))
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

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    ContentView()
}
