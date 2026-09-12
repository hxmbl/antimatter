import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = PaneStyle.cornerRadius

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        guard let layer = view.layer, layer.cornerRadius != cornerRadius else { return }
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = layer.presentation()?.cornerRadius ?? layer.cornerRadius
        animation.toValue = cornerRadius
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.cornerRadius = cornerRadius
        layer.add(animation, forKey: "cornerRadius")
    }
}
