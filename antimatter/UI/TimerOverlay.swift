import SwiftUI
import AppKit
import Combine

struct TimerOverlay: View {
    let timer: ActiveTimer
    let onDismiss: () -> Void

    @State private var remaining: TimeInterval
    @State private var isFired = false

    init(timer: ActiveTimer, onDismiss: @escaping () -> Void) {
        self.timer = timer
        self.onDismiss = onDismiss
        let remaining = max(0, timer.endDate.timeIntervalSinceNow)
        _remaining = State(initialValue: remaining)
        _isFired = State(initialValue: remaining <= 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                if let name = timer.name {
                    Text(name)
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                }

                Text(timeString)
                    .font(.system(size: 96, weight: .thin, design: .rounded))
                    .foregroundColor(isFired ? .red : .white)
                    .contentTransition(.numericText())

                Text(timer.label)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))

                if isFired {
                    Button("Dismiss") { onDismiss() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            remaining = max(0, timer.endDate.timeIntervalSinceNow)
            if remaining <= 0 && !isFired {
                isFired = true
            }
        }
        .onTapGesture { onDismiss() }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    private var timeString: String {
        let total = Int(remaining)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

final class TimerOverlayWindow {
    static let shared = TimerOverlayWindow()
    private var window: NSWindow?

    func show(timer: ActiveTimer) {
        dismiss()
        let panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(
            rootView: TimerOverlay(timer: timer) { [weak self] in
                self?.dismiss()
            }
        )
        panel.orderFrontRegardless()
        window = panel
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
