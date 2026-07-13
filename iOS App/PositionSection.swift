// PositionSection.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

struct PositionSection: View {
    let analytics: MatchAnalytics

    private var estimate: PositionEstimate { analytics.position }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                PositionBadge(role: estimate.role, side: estimate.side, confidence: estimate.confidence)
                    .scaleEffect(1.4)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(PositionBadge.fullName(role: estimate.role, side: estimate.side))
                        .font(.title3.weight(.semibold))
                    Text("Confidence \(Int(estimate.confidence * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            PositionPitch(estimate: estimate)
                .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                .background(Color.green.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))

            ThirdsBars(shares: thirdShares)
        }
    }

    /// Share of positional occupancy across defensive / middle / attacking thirds (long axis).
    private var thirdShares: [Double] {
        let heatmap = analytics.heatmap
        guard heatmap.columns > 0, heatmap.rows > 0 else { return [0, 0, 0] }
        var thirds = [0.0, 0.0, 0.0]
        for column in 0..<heatmap.columns {
            let third = min(2, column * 3 / heatmap.columns)
            for row in 0..<heatmap.rows {
                thirds[third] += heatmap[column, row]
            }
        }
        let total = thirds.reduce(0, +)
        guard total > 0 else { return [0, 0, 0] }
        return thirds.map { $0 / total }
    }
}

/// Mini pitch with the mean point and per-period points.
struct PositionPitch: View {
    let estimate: PositionEstimate

    var body: some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size, padding: 8)
            context.fill(Path(rect), with: .color(Color(red: 0.20, green: 0.55, blue: 0.25)))
            var pitch = context
            SoccerPitch.draw(in: &pitch, rect: rect, lineColor: .white.opacity(0.9))

            func place(_ point: CGPoint) -> CGPoint {
                CGPoint(x: rect.minX + CGFloat(point.x) * rect.width,
                        y: rect.minY + CGFloat(point.y) * rect.height)
            }

            // Per-period points (smaller, semi-transparent) with connecting order labels.
            for (index, point) in estimate.periodMeanPoints.enumerated() {
                let center = place(point)
                let dot = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: dot), with: .color(estimate.role.tint.opacity(0.55)))
                context.draw(Text("\(index + 1)").font(.caption2.bold()).foregroundColor(.white), at: center)
            }

            // Mean point (large).
            let mean = place(estimate.meanPoint)
            let ring = CGRect(x: mean.x - 11, y: mean.y - 11, width: 22, height: 22)
            context.fill(Path(ellipseIn: ring), with: .color(estimate.role.tint))
            context.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 2)
        }
    }
}

struct ThirdsBars: View {
    let shares: [Double]
    private let labels = ["Defensive", "Middle", "Attacking"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share of Thirds").font(.headline)
            ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                HStack(spacing: 10) {
                    Text(labels[index]).font(.caption).frame(width: 74, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(Color.accentColor)
                                .frame(width: geometry.size.width * share)
                        }
                    }
                    .frame(height: 12)
                    Text("\(Int(share * 100))%").font(.caption).monospacedDigit()
                        .frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
                }
            }
        }
    }
}
