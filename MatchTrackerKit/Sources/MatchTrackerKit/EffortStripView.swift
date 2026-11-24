#if canImport(SwiftUI)
import SwiftUI

/// A session with no pitch to draw, as a hooped shirt: playing in yarn, resting bare, kickoff first. Portrait, so
/// it sits beside the heat of outdoor matches, or landscape for wide places.
public struct EffortStripView: View {
    let levels: [Float]
    let axis: Axis
    let hasTurf: Bool

    public init(levels: [Float], axis: Axis = .vertical, hasTurf: Bool = true) {
        self.levels = levels
        self.axis = axis
        self.hasTurf = hasTurf
    }

    public var body: some View {
        Canvas { context, size in
            if hasTurf {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Cloth.shirt))
            }
            let along = axis == .vertical ? size.height : size.width
            let across = axis == .vertical ? size.width : size.height
            let margin = min(along, across) * (hasTurf ? 0.08 : 0)
            let slice = (along - margin * 2) / CGFloat(max(levels.count, 1))
            for (index, level) in levels.enumerated() {
                let offset = margin + CGFloat(index) * slice
                // A hooped shirt: full width while playing, and bare cloth with a thread while not.
                let length = level > 0 ? across : min(across * 0.06, 8)
                let thickness = level > 0 ? slice + 0.3 : max(slice * 0.3, 0.7)
                let rect = axis == .vertical
                    ? CGRect(x: (across - length) / 2, y: offset + (slice - thickness) / 2, width: length, height: thickness)
                    : CGRect(x: offset + (slice - thickness) / 2, y: (across - length) / 2, width: thickness, height: length)
                context.fill(Path(rect), with: .color(color(level)))
            }
        }
        .accessibilityHidden(true)
    }

    /// The knit's yarns: the harder, the paler.
    private func color(_ level: Float) -> Color {
        switch level {
        case ...0: return Cloth.ivory.opacity(0.35)
        case ..<0.6: return Color(cgColor: Knit.yarns[1])
        case ..<0.85: return Color(cgColor: Knit.yarns[2])
        default: return Cloth.ivory
        }
    }
}
#endif
