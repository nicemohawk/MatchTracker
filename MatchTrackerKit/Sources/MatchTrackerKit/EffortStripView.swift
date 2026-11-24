#if canImport(SwiftUI)
import SwiftUI

/// A session with no pitch to draw: its playing and resting on dark turf, kickoff first. Portrait, so
/// it sits beside the heat of outdoor matches, or landscape for wide places.
public struct EffortStripView: View {
    let levels: [Float]
    let axis: Axis

    public init(levels: [Float], axis: Axis = .vertical) {
        self.levels = levels
        self.axis = axis
    }

    public var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.055, green: 0.176, blue: 0.129), Color(red: 0.020, green: 0.086, blue: 0.071)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let along = axis == .vertical ? size.height : size.width
            let across = axis == .vertical ? size.width : size.height
            let margin = min(along, across) * 0.1
            let slice = (along - margin * 2) / CGFloat(max(levels.count, 1))
            for (index, level) in levels.enumerated() {
                let offset = margin + CGFloat(index) * slice
                let length = level > 0 ? (across - margin * 2) * CGFloat(0.35 + 0.65 * level) : across * 0.04
                let thickness = max(slice * 0.72, 0.8)
                let rect = axis == .vertical
                    ? CGRect(x: (across - length) / 2, y: offset, width: length, height: thickness)
                    : CGRect(x: offset, y: (across - length) / 2, width: thickness, height: length)
                context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color(level)))
            }
        }
        .accessibilityHidden(true)
    }

    /// The heat pitch's greens: deep, then bright, then pale at the hardest.
    private func color(_ level: Float) -> Color {
        guard level > 0 else { return .white.opacity(0.22) }
        let glow = Double(max(0, (level - 0.55) / 0.45))
        return Color(red: 0.10 + 0.70 * glow, green: 0.62 + 0.36 * glow, blue: 0.30 + 0.40 * glow)
    }
}
#endif
