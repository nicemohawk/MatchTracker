// HeatPitch.swift
// MatchTracker
//
// The app's signature picture: an upright pitch, always attacking up, with the player's time on it
// as smooth heat. Value types in, pixels out — no models, no theme — so widgets, cards and the
// replay video all draw exactly the same thing.

import SwiftUI
import MatchTrackerKit

/// Something worth marking on the pitch.
struct PitchMark: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case goal, assist }
    var kind: Kind
    var point: PitchPoint
    var scale: Double = 1
}

/// A run drawn as a tapering line toward where it finished.
struct PitchRun: Hashable, Sendable {
    var points: [PitchPoint]
    var isBest = false
    /// Written where it finished.
    var label: String?
    /// How much of it has been run, 0...1.
    var progress: Double = 1
    var opacity: Double = 1
    /// What it's drawn in; ivory unless told.
    var yarn: KitColors.RGB?
}

struct HeatPitch: View {
    enum Surface: Hashable, Sendable {
        case turf
        /// Lines and heat only, for drawing over something else.
        case clear
    }

    var heat: PitchHeat
    /// The fully-hot level for heat still building up; nil for heat that's its own measure.
    var heatReference: Float?
    var heatOpacity: Double = 1
    var size: PitchSize = .standard
    var marks: [PitchMark] = []
    var runs: [PitchRun] = []
    var averagePosition: PitchPoint?
    /// Where the player is right now, when scrubbing a replay.
    var currentPosition: PitchPoint?
    /// Where they've just been, oldest first.
    var trail: [PitchPoint] = []
    var surface: Surface = .turf
    /// Space kept around the lines; the turf still fills the whole view. Nil fits a natural run-off.
    var insets: EdgeInsets?
    /// When false, the picture doesn't claim to know which end is which.
    var directionIsKnown = true
    /// Draw the heat before returning rather than fading it in. For widgets and rendered images,
    /// which get one pass.
    var rendersImmediately = false

    @State private var renderer = HeatRenderer()

    /// The shape to give this view so the turf hugs the pitch.
    static func aspectRatio(for size: PitchSize) -> CGFloat { PitchArtist.naturalAspectRatio(for: size) }

    var body: some View {
        GeometryReader { proxy in
            let fullWidth = heatReference == nil ? 540 : 300
            let key = HeatImage.Key(heat: heat, size: size, pixelWidth: proxy.size.width > 90 ? fullWidth : 120,
                                    reference: heatReference)
            // Until it's ready, what was there before: a picture that blinks is worse than a late one.
            let image = HeatImage.cached(key) ?? (rendersImmediately ? HeatImage.make(key) : nil) ?? renderer.image
            let isShown = image != nil && !heat.isEmpty
            let insets = insets
            ZStack {
                if surface == .turf { Turf(size: size, insets: insets).equatable() }
                Canvas { context, canvasSize in
                    context.withCGContext { cg in
                        if let image { artist(canvasSize, insets).drawHeat(image, in: cg) }
                    }
                }
                .opacity(isShown ? heatOpacity : 0)
                .animation(rendersImmediately ? nil : .easeOut(duration: 0.35), value: isShown)
                .animation(rendersImmediately ? nil : .easeOut(duration: 0.35), value: heatOpacity)
                Canvas { context, canvasSize in
                    context.withCGContext { cg in
                        artist(canvasSize, insets).drawMarkings(in: cg, opacity: surface == .turf ? 0.5 : 0.75)
                    }
                }
                if !runs.isEmpty {
                    PitchRuns(runs: runs, artist: artist(proxy.size, insets), drawsOn: !rendersImmediately)
                }
                Canvas { context, canvasSize in
                    context.withCGContext { cg in drawOverlays(artist(canvasSize, insets), in: cg) }
                }
            }
            .onChange(of: key, initial: true) { if !rendersImmediately { renderer.show(key) } }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(PitchSentence.describe(
            heat, directionIsKnown: directionIsKnown,
            goals: marks.filter { $0.kind == .goal }.count, assists: marks.filter { $0.kind == .assist }.count))
    }

    private func artist(_ canvas: CGSize, _ insets: EdgeInsets?) -> PitchArtist {
        PitchArtist(size: size, canvas: canvas, insets: insets)
    }

    /// Thousands of stitches that never change, kept apart from what moves over them.
    private struct Turf: View, Equatable {
        let size: PitchSize
        let insets: EdgeInsets?
        var kit = KitColors.current

        var body: some View {
            let size = size, insets = insets
            Canvas { context, canvas in
                context.withCGContext { PitchArtist(size: size, canvas: canvas, insets: insets).drawTurf(in: $0) }
            }
        }
    }

    private func drawOverlays(_ artist: PitchArtist, in cg: CGContext) {
        guard !artist.isThumbnail else { return }
        if let averagePosition { artist.drawAverage(averagePosition, in: cg) }
        for mark in marks { artist.drawMark(mark, in: cg, scale: mark.scale) }
        artist.drawTrail(trail, in: cg)
        if let currentPosition { artist.drawPlayer(currentPosition, in: cg) }
    }
}

// MARK: - Runs

/// The runs, drawn one after another when they first appear.
private struct PitchRuns: View {
    let runs: [PitchRun]
    let artist: PitchArtist
    let drawsOn: Bool

    @State private var seconds = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Between one run starting and the next.
    fileprivate static let drawing = 0.45

    /// However many there are, they're all down in about a second.
    fileprivate static func stagger(_ count: Int) -> Double { min(0.15, 0.6 / Double(max(count, 1))) }

    var body: some View {
        let total = Self.drawing + Self.stagger(runs.count) * Double(runs.count)
        let isDrawnOn = drawsOn && !reduceMotion
        PitchRunsCanvas(runs: runs, artist: artist, seconds: isDrawnOn ? seconds : total)
            .onAppear { withAnimation(.linear(duration: total)) { seconds = total } }
    }
}

private struct PitchRunsCanvas: View, Animatable {
    let runs: [PitchRun]
    let artist: PitchArtist
    var seconds: Double

    var animatableData: Double {
        get { seconds }
        set { seconds = newValue }
    }

    var body: some View {
        Canvas { context, canvasSize in
            guard !artist.isThumbnail else { return }
            let best = runs.filter(\.isBest), others = runs.filter { !$0.isBest }
            for (position, run) in (best + others).enumerated().reversed() {
                let drawn = min((seconds - Double(position) * PitchRuns.stagger(runs.count)) / PitchRuns.drawing, run.progress)
                context.withCGContext { cg in
                    artist.drawRun(run, in: cg, opacity: run.opacity, progress: drawn)
                }
                guard drawn >= 1, let label = run.label, let tip = run.points.last else { continue }
                let text = context.resolve(Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.white))
                let size = text.measure(in: canvasSize)
                context.draw(text, in: place(size, beside: artist.place(tip), in: canvasSize))
            }
        }
    }

    /// Beside the tip, wherever it covers least of any run.
    private func place(_ size: CGSize, beside tip: CGPoint, in canvas: CGSize) -> CGRect {
        let reach = artist.pitch.width * 0.065
        let bounds = CGRect(origin: .zero, size: canvas).insetBy(dx: 8, dy: 8)
        let lines = runs.flatMap { $0.points.map(artist.place) }
        let spots = [CGPoint(x: tip.x + reach, y: tip.y - size.height / 2),
                     CGPoint(x: tip.x - reach - size.width, y: tip.y - size.height / 2),
                     CGPoint(x: tip.x - size.width / 2, y: tip.y - reach - size.height),
                     CGPoint(x: tip.x - size.width / 2, y: tip.y + reach)]
            .map { CGRect(origin: $0, size: size) }
        let open = spots.filter { bounds.contains($0) }
        return (open.isEmpty ? spots : open).min { first, second in
            lines.filter(first.contains).count < lines.filter(second.contains).count
        } ?? spots[0]
    }
}

// MARK: - Heat image

/// Renders the latest heat asked for, off the main thread, and holds the last one it finished. Heat
/// that changes faster than it can be drawn skips frames rather than never arriving.
@MainActor
@Observable
private final class HeatRenderer {
    private(set) var image: CGImage?
    @ObservationIgnored private var wanted: HeatImage.Key?
    @ObservationIgnored private var work: Task<Void, Never>?

    func show(_ key: HeatImage.Key) {
        if let cached = HeatImage.cached(key) {
            wanted = nil
            image = cached
            return
        }
        wanted = key
        guard work == nil else { return }
        work = Task {
            while let key = wanted {
                wanted = nil
                if let made = await Task.detached(priority: .userInitiated, operation: { HeatImage.make(key) }).value {
                    image = made
                }
            }
            work = nil
        }
    }
}

/// Turns a coarse grid into a smooth, transparent-to-bright image. Pure; safe off the main actor.
enum HeatImage {
    struct Key: Hashable, Sendable {
        var heat: PitchHeat
        var size: PitchSize
        var pixelWidth: Int
        /// The fully-hot level, or nil to use this heat's own.
        var reference: Float?
        var kit = KitColors.current
    }

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private final class BoxedKey: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? BoxedKey)?.key == key }
    }

    /// NSCache is thread-safe and empties itself under memory pressure.
    private nonisolated(unsafe) static let cache: NSCache<BoxedKey, Box> = {
        let cache = NSCache<BoxedKey, Box>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func cached(_ key: Key) -> CGImage? {
        key.reference == nil ? cache.object(forKey: BoxedKey(key))?.image : nil
    }

    static func make(_ key: Key) -> CGImage? {
        if let image = cached(key) { return image }
        guard let image = render(key.heat, size: key.size, pixelWidth: key.pixelWidth, reference: key.reference, kit: key.kit) else { return nil }
        // A frame of something playing won't be asked for again.
        guard key.reference == nil else { return image }
        cache.setObject(Box(image), forKey: BoxedKey(key), cost: image.bytesPerRow * image.height)
        return image
    }

    /// The level that counts as fully hot once smoothed: high enough that a minute spent tying a
    /// lace doesn't wash out everywhere else.
    static func reference(for heat: PitchHeat, size: PitchSize) -> Float {
        let smoothed = smooth(heat, size: size)
        let occupied = smoothed.filter { $0 > 0 }.sorted()
        guard !occupied.isEmpty else { return 0 }
        return occupied[min(occupied.count - 1, Int(Double(occupied.count) * 0.997))]
    }

    /// - Parameter reference: The fully-hot level, or nil to use this heat's own.
    static func render(_ heat: PitchHeat, size: PitchSize, pixelWidth: Int, reference: Float?,
                       kit: KitColors = .current) -> CGImage? {
        let reference = reference ?? self.reference(for: heat, size: size)
        let width = max(8, pixelWidth)
        let height = max(8, Int((Double(width) / size.aspectRatio).rounded()))
        guard reference > 0 else { return nil }
        let columns = Knit.columns(across: CGFloat(width))
        let stitch = CGFloat(width) / CGFloat(columns)
        let rows = max(1, Int((CGFloat(height) / (stitch * Knit.rise)).rounded()))
        let field = upscale(smooth(heat, size: size), columns: heat.columns, rows: heat.rows, width: columns, height: rows)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let paths = Knit.yarns.map { _ in CGMutablePath() }
        for row in 0..<rows {
            for column in 0..<columns {
                // Lift the low end so a wandering midfielder's whole game shows, not just one hot spot.
                let level = powf(min(max(field[row * columns + column] / reference, 0), 1), 0.5)
                guard let yarn = Knit.yarn(for: level) else { continue }
                Knit.addStitch(to: paths[yarn], column: column, row: row, width: stitch)
            }
        }
        for (path, yarn) in zip(paths, kit.yarns) {
            cg.setFillColor(yarn.cgColor)
            cg.addPath(path)
            cg.fillPath()
        }
        return cg.makeImage()
    }

    /// How far a fix spreads. About GPS's own uncertainty, so the picture claims no more than it knows.
    private static let spreadMeters = 3.0

    private static func smooth(_ heat: PitchHeat, size: PitchSize) -> [Float] {
        let cellAcross = size.widthMeters / Double(heat.columns)
        let cellAlong = size.lengthMeters / Double(heat.rows)
        guard cellAcross > 0, cellAlong > 0 else { return heat.values }
        // A small pitch gets a proportionally smaller spread, or it would be one blob.
        let spread = spreadMeters * max(0.6, size.markingScale)
        let across = blur(heat.values, columns: heat.columns, rows: heat.rows, sigma: spread / cellAcross, stride: 1)
        return blur(across, columns: heat.columns, rows: heat.rows, sigma: spread / cellAlong, stride: heat.columns)
    }

    /// Gaussian along one axis, renormalized at the edges so the touchline doesn't look cold.
    private static func blur(_ values: [Float], columns: Int, rows: Int, sigma: Double, stride: Int) -> [Float] {
        let radius = Int((sigma * 3).rounded(.up))
        guard radius > 0 else { return values }
        let kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        var result = [Float](repeating: 0, count: values.count)
        for index in values.indices {
            let position = stride == 1 ? index % columns : index / columns
            let limit = stride == 1 ? columns : rows
            var total: Float = 0, weight: Float = 0
            for offset in max(-radius, -position)...min(radius, limit - 1 - position) {
                total += values[index + offset * stride] * kernel[offset + radius]
                weight += kernel[offset + radius]
            }
            result[index] = total / weight
        }
        return result
    }

    /// Cubic B-spline: no seams, no ringing, no overshoot. Flat buffers because the replay does this
    /// for every frame.
    private static func upscale(_ values: [Float], columns: Int, rows: Int, width: Int, height: Int) -> [Float] {
        func taps(_ count: Int, from source: Int) -> (indices: [Int], weights: [Float]) {
            var indices: [Int] = [], weights: [Float] = []
            for position in 0..<count {
                let center = (Float(position) + 0.5) / Float(count) * Float(source) - 0.5
                let base = Int(center.rounded(.down))
                let t = center - Float(base)
                indices += (-1...2).map { min(max(base + $0, 0), source - 1) }
                weights += [(1 - t) * (1 - t) * (1 - t) / 6,
                            (3 * t * t * t - 6 * t * t + 4) / 6,
                            (-3 * t * t * t + 3 * t * t + 3 * t + 1) / 6,
                            t * t * t / 6]
            }
            return (indices, weights)
        }
        let horizontal = taps(width, from: columns), vertical = taps(height, from: rows)
        var wide = [Float](repeating: 0, count: width * rows)
        for row in 0..<rows {
            let offset = row * columns
            for x in 0..<width {
                var total: Float = 0
                for tap in (x * 4)..<(x * 4 + 4) { total += values[offset + horizontal.indices[tap]] * horizontal.weights[tap] }
                wide[row * width + x] = total
            }
        }
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for tap in (y * 4)..<(y * 4 + 4) {
                let source = vertical.indices[tap] * width, weight = vertical.weights[tap], target = y * width
                for x in 0..<width { result[target + x] += wide[source + x] * weight }
            }
        }
        return result
    }
}

// MARK: - Drawing

/// Draws the pitch into any top-left-origin CGContext. Shared by the view and the replay video.
struct PitchArtist: Sendable {
    let size: PitchSize
    /// Everything that gets turf.
    let bounds: CGRect
    /// Inside the touchlines.
    let pitch: CGRect
    let pointsPerMeter: CGFloat

    /// Grass outside the lines, in meters.
    private static let runOff: CGFloat = 4.5

    init(size: PitchSize, bounds: CGRect, insets: UIEdgeInsets? = nil) {
        self.size = size
        self.bounds = bounds
        let available: CGRect
        if let insets {
            available = bounds.inset(by: insets)
        } else {
            // Thumbnails spend their few points on the pitch, not the grass around it.
            let share = bounds.width < 90 ? 0.05 : Self.runOff / (CGFloat(size.widthMeters) + 2 * Self.runOff)
            available = bounds.insetBy(dx: bounds.width * share, dy: bounds.width * share)
        }
        let aspect = CGFloat(size.aspectRatio)
        let width = max(0, min(available.width, available.height * aspect))
        pitch = CGRect(x: available.midX - width / 2, y: available.midY - width / aspect / 2,
                       width: width, height: width / aspect)
        pointsPerMeter = width / CGFloat(max(size.widthMeters, 1))
    }

    init(size: PitchSize, canvas: CGSize, insets: EdgeInsets?) {
        self.init(size: size, bounds: CGRect(origin: .zero, size: canvas),
                  insets: insets.map { UIEdgeInsets(top: $0.top, left: $0.leading, bottom: $0.bottom, right: $0.trailing) })
    }

    static func naturalAspectRatio(for size: PitchSize) -> CGFloat {
        let width = CGFloat(max(size.widthMeters, 1))
        return (width + 2 * runOff) / (width / CGFloat(size.aspectRatio) + 2 * runOff)
    }

    var isThumbnail: Bool { pitch.width < 80 }

    func place(_ point: PitchPoint) -> CGPoint {
        CGPoint(x: pitch.minX + CGFloat(point.across) * pitch.width,
                y: pitch.maxY - CGFloat(point.up) * pitch.height)
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func white(_ alpha: CGFloat) -> CGColor { color(1, 1, 1, alpha) }

    // MARK: Turf

    func drawTurf(in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: bounds)
        cg.setFillColor(Knit.cloth)
        cg.fill(bounds)
        guard !isThumbnail, pitch.height > 0 else { return }
        // The whole cloth is knitted; the heat only changes the yarn.
        let stitch = pitch.width / CGFloat(Knit.columns(across: pitch.width * 3))
        let left = Int(((pitch.minX - bounds.minX) / stitch).rounded(.up)), up = Int(((pitch.minY - bounds.minY) / (stitch * Knit.rise)).rounded(.up))
        let columns = left + Int(((bounds.maxX - pitch.minX) / stitch).rounded(.up)), rows = up + Int(((bounds.maxY - pitch.minY) / (stitch * Knit.rise)).rounded(.up))
        let path = CGMutablePath()
        for row in -up..<(rows - up) {
            for column in -left..<(columns - left) {
                Knit.addStitch(to: path, column: column, row: row, width: stitch, origin: pitch.origin)
            }
        }
        cg.setFillColor(Knit.ground)
        cg.addPath(path)
        cg.fillPath()
    }

    func drawHeat(_ image: CGImage, in cg: CGContext, opacity: CGFloat = 1) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: pitch)
        cg.interpolationQuality = .high
        cg.setAlpha(opacity)
        // Images draw bottom-up; this context is top-down.
        cg.translateBy(x: pitch.minX, y: pitch.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: pitch.size))
    }

    // MARK: Markings

    /// - Parameter progress: 0...1 draws the lines in, for the replay's opening.
    func drawMarkings(in cg: CGContext, opacity: CGFloat = 0.5, progress: CGFloat = 1) {
        guard pitch.width > 0, progress > 0 else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        let lineWidth = max(isThumbnail ? 0.75 : 1, pitch.width * 0.0048)
        cg.setLineWidth(lineWidth)
        cg.setLineJoin(.miter)
        cg.setLineCap(.butt)
        cg.setStrokeColor(white(1))
        cg.setFillColor(white(1))
        // One layer, so lines don't get brighter where they cross.
        cg.setAlpha(opacity)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg.endTransparencyLayer() }
        for path in markingPaths() {
            if progress < 1 {
                let length = path.approximateLength
                cg.setLineDash(phase: 0, lengths: [length * progress, length])
            }
            cg.addPath(path.cgPath)
            cg.strokePath()
        }
        guard !isThumbnail, progress >= 1 else { return }
        let scale = CGFloat(size.markingScale) * pointsPerMeter
        let spot = max(1.2, lineWidth * 1.05)
        for center in [CGPoint(x: pitch.midX, y: pitch.midY),
                       CGPoint(x: pitch.midX, y: pitch.minY + 11 * scale),
                       CGPoint(x: pitch.midX, y: pitch.maxY - 11 * scale)] {
            cg.fillEllipse(in: CGRect(x: center.x - spot, y: center.y - spot, width: spot * 2, height: spot * 2))
        }
        // Goals, behind the lines.
        cg.setLineWidth(lineWidth * 0.8)
        cg.setStrokeColor(white(0.8))
        let goal = CGSize(width: 7.32 * scale, height: 2.2 * scale)
        for y in [pitch.minY - goal.height, pitch.maxY] {
            let box = CGRect(x: pitch.midX - goal.width / 2, y: y, width: goal.width, height: goal.height)
            cg.setFillColor(white(0.12))
            cg.fill(box)
            cg.stroke(box)
        }
    }

    private struct MarkingPath {
        let cgPath: CGPath
        let approximateLength: CGFloat
    }

    private func markingPaths() -> [MarkingPath] {
        // The laws measure markings in meters; a small pitch's are scaled down with it.
        let scale = CGFloat(size.markingScale) * pointsPerMeter
        let circle = 9.15 * scale
        var paths = [MarkingPath(cgPath: CGPath(rect: pitch, transform: nil), approximateLength: 2 * (pitch.width + pitch.height))]
        let halfway = CGMutablePath()
        halfway.move(to: CGPoint(x: pitch.minX, y: pitch.midY))
        halfway.addLine(to: CGPoint(x: pitch.maxX, y: pitch.midY))
        paths.append(MarkingPath(cgPath: halfway, approximateLength: pitch.width))
        paths.append(MarkingPath(
            cgPath: CGPath(ellipseIn: CGRect(x: pitch.midX - circle, y: pitch.midY - circle, width: circle * 2, height: circle * 2),
                           transform: nil),
            approximateLength: 2 * .pi * circle))
        for isTop in [true, false] {
            let line = isTop ? pitch.minY : pitch.maxY
            let inward: CGFloat = isTop ? 1 : -1
            func box(depth: CGFloat, width: CGFloat) -> MarkingPath {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: pitch.midX - width / 2, y: line))
                path.addLine(to: CGPoint(x: pitch.midX - width / 2, y: line + inward * depth))
                path.addLine(to: CGPoint(x: pitch.midX + width / 2, y: line + inward * depth))
                path.addLine(to: CGPoint(x: pitch.midX + width / 2, y: line))
                return MarkingPath(cgPath: path, approximateLength: 2 * depth + width)
            }
            paths.append(box(depth: 16.5 * scale, width: 40.32 * scale))
            guard !isThumbnail else { continue }
            paths.append(box(depth: 5.5 * scale, width: 18.32 * scale))
            // The D: the part of the 9.15 m circle around the spot that's outside the box.
            let half = acos(5.5 / 9.15)
            let toward: CGFloat = isTop ? .pi / 2 : -.pi / 2
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: pitch.midX, y: line + inward * 11 * scale), radius: circle,
                       startAngle: toward - half, endAngle: toward + half, clockwise: false)
            paths.append(MarkingPath(cgPath: arc, approximateLength: 2 * half * circle))
            for isLeft in [true, false] {
                let corner = CGPoint(x: isLeft ? pitch.minX : pitch.maxX, y: line)
                let start: CGFloat = isTop ? (isLeft ? 0 : .pi / 2) : (isLeft ? -.pi / 2 : .pi)
                let quarter = CGMutablePath()
                quarter.addArc(center: corner, radius: 1.2 * scale, startAngle: start, endAngle: start + .pi / 2, clockwise: false)
                paths.append(MarkingPath(cgPath: quarter, approximateLength: 0.6 * .pi * scale))
            }
        }
        return paths
    }

    // MARK: Overlays

    /// A run, tapering in from its start. `progress` grows it, for the replay.
    func drawRun(_ run: PitchRun, in cg: CGContext, opacity: CGFloat = 1, progress: CGFloat = 1) {
        let path = Self.smoothed(run.points.map(place))
        let count = Int((CGFloat(path.count) * min(max(progress, 0), 1)).rounded())
        guard count >= 2 else { return }
        let visible = Array(path.prefix(count))
        let width = pitch.width * (run.isBest ? 0.014 : 0.00875)
        // Faded as one thing, so the head and line don't show through each other.
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setAlpha(opacity)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg.endTransparencyLayer() }
        if run.isBest {
            // A dark edge keeps it legible over the hottest heat.
            drawTapered(visible, in: cg, width: width * 1.9, color: (0.01, 0.05, 0.04), opacity: 0.55)
        }
        let yarn = run.yarn ?? KitColors.ivory
        drawTapered(visible, in: cg, width: width, color: (yarn.red, yarn.green, yarn.blue), opacity: 1)
        // Mid-run, the player is the tip.
        guard progress >= 1, let tip = visible.last else { return }
        let back = visible[max(0, visible.count - 1 - max(2, visible.count / 8))]
        let angle = atan2(tip.y - back.y, tip.x - back.x)
        let head = width * 2.4
        cg.saveGState()
        cg.translateBy(x: tip.x, y: tip.y)
        cg.rotate(by: angle)
        cg.move(to: CGPoint(x: head, y: 0))
        cg.addLine(to: CGPoint(x: -head * 0.7, y: head * 0.85))
        cg.addLine(to: CGPoint(x: -head * 0.35, y: 0))
        cg.addLine(to: CGPoint(x: -head * 0.7, y: -head * 0.85))
        cg.closePath()
        cg.setFillColor(yarn.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    /// The comet behind a moving player.
    func drawTrail(_ points: [PitchPoint], in cg: CGContext) {
        let trail = points.map(place)
        drawTapered(trail, in: cg, width: pitch.width * 0.029, color: (0.30, 0.93, 0.48), opacity: 0.2)
        drawTapered(trail, in: cg, width: pitch.width * 0.011, color: (0.93, 1, 0.94), opacity: 0.95)
    }

    /// A line that fades and thins toward its oldest end.
    func drawTapered(_ points: [CGPoint], in cg: CGContext, width: CGFloat,
                     color rgb: (CGFloat, CGFloat, CGFloat), opacity: CGFloat) {
        let points = Self.resampled(points, spacing: max(1.5, width * 0.3))
        guard points.count >= 2 else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        func halfWidth(_ index: Int) -> CGFloat {
            width / 2 * (0.25 + 0.75 * CGFloat(index) / CGFloat(points.count - 1))
        }
        // The outline of the whole line, so its edges are smooth; then the fade inside it, where each
        // newer stretch replaces what it overlaps rather than adding to it and beading.
        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in points.indices {
            let before = points[max(0, index - 1)], after = points[min(points.count - 1, index + 1)]
            let length = max(hypot(after.x - before.x, after.y - before.y), 0.0001)
            let normal = CGPoint(x: -(after.y - before.y) / length, y: (after.x - before.x) / length)
            let half = halfWidth(index)
            left.append(CGPoint(x: points[index].x + normal.x * half, y: points[index].y + normal.y * half))
            right.append(CGPoint(x: points[index].x - normal.x * half, y: points[index].y - normal.y * half))
        }
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg.endTransparencyLayer() }
        cg.addLines(between: left + right.reversed())
        cg.closePath()
        cg.clip()
        cg.setShouldAntialias(false)
        cg.setBlendMode(.copy)
        cg.setLineCap(.round)
        cg.setLineWidth(width * 1.6)
        for index in 0..<(points.count - 1) {
            let age = CGFloat(index + 1) / CGFloat(points.count - 1)
            cg.setStrokeColor(color(rgb.0, rgb.1, rgb.2, opacity * age * age))
            cg.move(to: points[index])
            cg.addLine(to: points[index + 1])
            cg.strokePath()
        }
    }

    func drawAverage(_ point: PitchPoint, in cg: CGContext) {
        let center = place(point)
        let radius = max(6, pitch.width * 0.045)
        let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        cg.saveGState()
        let line = max(1.5, pitch.width * 0.007)
        cg.setStrokeColor(color(0.01, 0.05, 0.04, 0.7))
        cg.setLineWidth(line * 2.4)
        cg.strokeEllipse(in: ring)
        cg.setStrokeColor(white(1))
        cg.setLineWidth(line)
        cg.strokeEllipse(in: ring)
        cg.setFillColor(color(0.01, 0.05, 0.04, 0.7))
        cg.fillEllipse(in: ring.insetBy(dx: radius * 0.68, dy: radius * 0.68))
        cg.setFillColor(white(1))
        let dot = radius * 0.2
        cg.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
        cg.restoreGState()
    }

    /// A ball for a goal, a pass arrow for an assist: told apart by shape, not color.
    func drawMark(_ mark: PitchMark, in cg: CGContext, scale: CGFloat = 1, opacity: CGFloat = 1) {
        let center = place(mark.point)
        let radius = max(5.5, pitch.width * 0.032) * scale
        guard radius > 0 else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setAlpha(opacity)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg.endTransparencyLayer() }
        cg.translateBy(x: center.x, y: center.y)
        let disc = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        let dark = color(0.015, 0.06, 0.05)
        cg.setFillColor(color(0.015, 0.06, 0.05, 0.55))
        cg.fillEllipse(in: disc.insetBy(dx: -radius * 0.22, dy: -radius * 0.22))
        switch mark.kind {
        case .goal:
            cg.setFillColor(white(1))
            cg.fillEllipse(in: disc)
            cg.setFillColor(dark)
            cg.setStrokeColor(dark)
            cg.setLineWidth(radius * 0.13)
            cg.addEllipse(in: disc)
            cg.clip()
            func corner(_ index: Int, _ distance: CGFloat, _ offset: CGFloat = 0) -> CGPoint {
                let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / 5 + offset
                return CGPoint(x: cos(angle) * distance * radius, y: sin(angle) * distance * radius)
            }
            cg.addLines(between: (0..<5).map { corner($0, 0.4) })
            cg.closePath()
            cg.fillPath()
            for index in 0..<5 {
                cg.move(to: corner(index, 0.4))
                cg.addLine(to: corner(index, 0.8))
                cg.strokePath()
                cg.addLines(between: [corner(index, 0.74), corner(index, 1.1, 0.34), corner(index, 1.1, -0.34)])
                cg.closePath()
                cg.fillPath()
            }
        case .assist:
            cg.setFillColor(dark)
            cg.fillEllipse(in: disc)
            cg.setStrokeColor(white(1))
            cg.setLineWidth(radius * 0.18)
            cg.strokeEllipse(in: disc.insetBy(dx: radius * 0.09, dy: radius * 0.09))
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            let reach = radius * 0.4
            cg.move(to: CGPoint(x: -reach, y: reach))
            cg.addLine(to: CGPoint(x: reach, y: -reach))
            cg.move(to: CGPoint(x: -reach * 0.35, y: -reach))
            cg.addLine(to: CGPoint(x: reach, y: -reach))
            cg.addLine(to: CGPoint(x: reach, y: reach * 0.35))
            cg.strokePath()
        }
    }

    func drawPlayer(_ point: PitchPoint, in cg: CGContext, opacity: CGFloat = 1) {
        let center = place(point)
        let radius = max(4.5, pitch.width * 0.022)
        func disc(_ scale: CGFloat) -> CGRect {
            CGRect(x: center.x - radius * scale, y: center.y - radius * scale,
                   width: radius * scale * 2, height: radius * scale * 2)
        }
        cg.saveGState()
        cg.setFillColor(color(0.01, 0.05, 0.04, 0.5 * opacity))
        cg.fillEllipse(in: disc(1.55))
        cg.setFillColor(white(opacity))
        cg.fillEllipse(in: disc(1))
        cg.setFillColor(color(0.09, 0.64, 0.29, opacity))
        cg.fillEllipse(in: disc(0.62))
        cg.restoreGState()
    }

    /// Evenly spaced along the line, so a fade along it has no visible steps.
    private static func resampled(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }
        var result = [first]
        var carried: CGFloat = 0
        for (from, to) in zip(points, points.dropFirst()) {
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { continue }
            var along = spacing - carried
            while along <= length {
                result.append(CGPoint(x: from.x + (to.x - from.x) * along / length, y: from.y + (to.y - from.y) * along / length))
                along += spacing
            }
            carried = length - (along - spacing)
        }
        if carried > 0 { result.append(last) }
        return result
    }

    /// A curve through the fixes, sampled evenly enough to draw as short segments.
    static func smoothed(_ points: [CGPoint], stepsPerSegment: Int = 6) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        var result: [CGPoint] = [points[0]]
        for index in 0..<(points.count - 1) {
            let before = points[max(0, index - 1)], from = points[index]
            let to = points[index + 1], after = points[min(points.count - 1, index + 2)]
            for step in 1...stepsPerSegment {
                let t = CGFloat(step) / CGFloat(stepsPerSegment)
                func catmullRom(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat) -> CGFloat {
                    0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                           + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t)
                }
                result.append(CGPoint(x: catmullRom(before.x, from.x, to.x, after.x),
                                      y: catmullRom(before.y, from.y, to.y, after.y)))
            }
        }
        return result
    }
}
