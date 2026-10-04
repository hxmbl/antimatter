import SwiftUI
import AppKit
import QuartzCore

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = PaneStyle.cornerRadius

    /// Carries what the view already has so `updateNSView` only touches the
    /// properties that actually changed. Re-asserting them on every SwiftUI
    /// update was pointless work and reset the material's own animation.
    final class Coordinator {
        var material: NSVisualEffectView.Material?
        var blendingMode: NSVisualEffectView.BlendingMode?
        var state: NSVisualEffectView.State?
        var cornerRadius: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        context.coordinator.material = material
        context.coordinator.blendingMode = blendingMode
        context.coordinator.state = .active
        context.coordinator.cornerRadius = cornerRadius
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.layer?.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.material != material {
            coordinator.material = material
            view.material = material
        }
        if coordinator.blendingMode != blendingMode {
            coordinator.blendingMode = blendingMode
            view.blendingMode = blendingMode
        }
        if coordinator.state != .active {
            coordinator.state = .active
            view.state = .active
        }
        guard let layer = view.layer else { return }
        layer.masksToBounds = true
        guard coordinator.cornerRadius != cornerRadius else { return }
        coordinator.cornerRadius = cornerRadius
        let from = layer.presentation()?.cornerRadius ?? layer.cornerRadius
        // The model layer's own cornerRadius has to change without its
        // implicit animation: layering the explicit CABasicAnimation on top of
        // that animated the corner twice.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = cornerRadius
        CATransaction.commit()
        guard from != cornerRadius else { return }
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = from
        animation.toValue = cornerRadius
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "cornerRadius")
    }
}