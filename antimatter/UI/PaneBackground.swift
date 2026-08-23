import SwiftUI
import AppKit

struct PaneBackground: View {
    var body: some View {
        ZStack {
            if PaneStyle.usesBlur {
                VisualEffectBackground(material: PaneStyle.material, blendingMode: PaneStyle.blending)
            }
            PaneStyle.tint.opacity(PaneStyle.tintOpacity)
        }
    }
}
