// SoccerPitch.swift
// MatchTracker

import SwiftUI

/// Draws standard soccer-pitch markings into a `Canvas` `GraphicsContext`, and provides an
/// aspect-correct rectangle (length:width = 105:68) fitted inside an available size.
/// The long axis runs horizontally (x), matching the Kit's normalized field space.
enum SoccerPitch {
    static let lengthMeters: CGFloat = 105
    static let widthMeters: CGFloat = 68
    static let aspect: CGFloat = lengthMeters / widthMeters

    /// Largest 105:68 rectangle fitting inside `size`, centered, inset by `padding`.
    static func fittedRect(in size: CGSize, padding: CGFloat = 8) -> CGRect {
        let available = CGSize(width: max(0, size.width - padding * 2),
                               height: max(0, size.height - padding * 2))
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        let x = (size.width - width) / 2
        let y = (size.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Fills a dark green-black turf gradient plus a soft vignette into `rect`.
    static func fillTurf(_ context: inout GraphicsContext, rect: CGRect) {
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Theme.pitchTurfTop, Theme.pitchTurfBottom]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        context.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(0.28)]),
            center: CGPoint(x: rect.midX, y: rect.midY),
            startRadius: rect.width * 0.18, endRadius: rect.width * 0.62))
    }

    static func draw(in context: inout GraphicsContext, rect: CGRect,
                     lineColor: Color = Theme.pitchLines, lineWidth: CGFloat = 1.5) {
        let scale = rect.width / lengthMeters   // pixels per meter
        func px(_ meters: CGFloat) -> CGFloat { meters * scale }
        let stroke = StrokeStyle(lineWidth: lineWidth, lineJoin: .round)
        let shading = GraphicsContext.Shading.color(lineColor)

        // Outer boundary.
        context.stroke(Path(rect), with: shading, style: stroke)

        // Halfway line.
        var halfway = Path()
        halfway.move(to: CGPoint(x: rect.midX, y: rect.minY))
        halfway.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        context.stroke(halfway, with: shading, style: stroke)

        // Center circle + spot.
        let centerRadius = px(9.15)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.stroke(Path(ellipseIn: CGRect(x: center.x - centerRadius, y: center.y - centerRadius,
                                               width: centerRadius * 2, height: centerRadius * 2)),
                       with: shading, style: stroke)
        context.fill(spot(at: center), with: shading)

        // Penalty + goal boxes and penalty spots/arcs, both ends.
        drawEnd(&context, rect: rect, px: px, shading: shading, stroke: stroke, leftSide: true)
        drawEnd(&context, rect: rect, px: px, shading: shading, stroke: stroke, leftSide: false)

        // Corner arcs.
        drawCornerArcs(&context, rect: rect, radius: px(1), shading: shading, stroke: stroke)
    }

    private static func drawEnd(_ context: inout GraphicsContext, rect: CGRect,
                                px: (CGFloat) -> CGFloat, shading: GraphicsContext.Shading,
                                stroke: StrokeStyle, leftSide: Bool) {
        let penaltyDepth = px(16.5)
        let penaltyHeight = px(40.32)
        let goalDepth = px(5.5)
        let goalHeight = px(18.32)
        let penaltyDistance = px(11)

        let goalLineX = leftSide ? rect.minX : rect.maxX
        let direction: CGFloat = leftSide ? 1 : -1

        func box(depth: CGFloat, height: CGFloat) -> Path {
            let rectX = leftSide ? goalLineX : goalLineX - depth
            return Path(CGRect(x: rectX, y: rect.midY - height / 2, width: depth, height: height))
        }
        context.stroke(box(depth: penaltyDepth, height: penaltyHeight), with: shading, style: stroke)
        context.stroke(box(depth: goalDepth, height: goalHeight), with: shading, style: stroke)

        // Penalty spot.
        let spotCenter = CGPoint(x: goalLineX + direction * penaltyDistance, y: rect.midY)
        context.fill(spot(at: spotCenter), with: shading)

        // Penalty arc — only the "D" beyond the box front. Angle-based addArc is fragile here
        // (SwiftUI's flipped coordinates invert `clockwise`, which silently turns the minor arc
        // into a near-full circle), so stroke the whole circle clipped to outside the box instead.
        let arcRadius = px(9.15)
        let circle = Path(ellipseIn: CGRect(x: spotCenter.x - arcRadius, y: spotCenter.y - arcRadius,
                                            width: arcRadius * 2, height: arcRadius * 2))
        let boxFrontX = goalLineX + direction * penaltyDepth
        let beyondBox = leftSide
            ? CGRect(x: boxFrontX, y: rect.minY, width: rect.maxX - boxFrontX, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY, width: boxFrontX - rect.minX, height: rect.height)
        context.drawLayer { layer in
            layer.clip(to: Path(beyondBox))
            layer.stroke(circle, with: shading, style: stroke)
        }
    }

    private static func drawCornerArcs(_ context: inout GraphicsContext, rect: CGRect,
                                       radius: CGFloat, shading: GraphicsContext.Shading, stroke: StrokeStyle) {
        let corners: [(CGPoint, Angle, Angle)] = [
            (CGPoint(x: rect.minX, y: rect.minY), .degrees(0), .degrees(90)),
            (CGPoint(x: rect.maxX, y: rect.minY), .degrees(90), .degrees(180)),
            (CGPoint(x: rect.maxX, y: rect.maxY), .degrees(180), .degrees(270)),
            (CGPoint(x: rect.minX, y: rect.maxY), .degrees(270), .degrees(360))
        ]
        for (point, start, end) in corners {
            var arc = Path()
            arc.addArc(center: point, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.stroke(arc, with: shading, style: stroke)
        }
    }

    private static func spot(at point: CGPoint, radius: CGFloat = 2) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
}
