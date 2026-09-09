import SwiftUI
import AppKit

struct PaneBackground: View {
    var body: some View {
        ZStack {
            if PaneStyle.usesBlur {
                VisualEffectBackground(material: PaneStyle.material, blendingMode: PaneStyle.blending)
            } else {
                PaneStyle.backgroundColor
            }
            PaneStyle.tint.opacity(PaneStyle.tintOpacity)
            if PaneStyle.gridPaper {
                GridPaperView()
            }
        }
    }
}

struct GridPaperView: View {
    let spacing: CGFloat = 20

    var body: some View {
        Canvas { context, size in
            let path = Path { path in
                var x: CGFloat = 0
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
            }
            context.stroke(path, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
        }
    }
}