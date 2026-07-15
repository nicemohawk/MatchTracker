// SatelliteFieldDetector.swift
// MatchTracker

import Foundation
import CoreLocation
import CoreImage
import Vision
import MapKit
import UIKit
import simd
import MatchTrackerKit

/// On-device satellite-imagery pitch detection tuned for REAL conditions (worn grass with brown
/// patches, faint chalk lines, adjacent pitches, trees/shadows at the edges) rather than the
/// idealised "vivid green + brilliant white lines" case.
///
/// Pipeline (all on-device, no ML training required):
///  1. Snapshot Apple Maps satellite tiles for the region — at two zoom-equivalent scales so a
///     pitch whose touchlines run near the frame edge is still fully framed at the wider scale.
///  2. Generate quadrilateral CANDIDATES with `VNDetectRectanglesRequest`, which keys on edge
///     gradients (not absolute whiteness) and so survives faint/worn markings. Run it on both the
///     raw image and a line-enhanced (unsharp) image to recover low-contrast touchlines.
///  3. SCORE each candidate with hue-tolerant grass evidence (a wide green→yellow→brown band, so
///     worn turf still reads as field) plus line evidence from a LOCAL brightness ridge (a marking
///     is brighter than the turf a few px to either side — never an absolute white threshold) plus
///     an aspect-ratio prior. Grass-dominant interior is required, which rejects parking lots,
///     rooftops, water and tennis courts.
///  4. Non-max suppression across overlapping candidates, then map pixel corners back to coords.
///
/// All best-effort — returns [] / nil on any failure. The public API is unchanged and remains
/// async + cancellable. Never runs on watchOS (no snapshotter there).
struct SatelliteFieldDetector {
    struct Proposal {
        var rectangle: OrientedRectangle
        var score: Double
    }

#if DEBUG
    /// A detector is constructed during normal app startup (NearbyFieldSeeder owns one), which lets
    /// the DEBUG validation harness self-trigger off a launch argument without touching app-launch
    /// code. No-op unless `-RunDetectorValidation` is present; runs at most once per process.
    init() { SatelliteDetectorValidation.bootstrapIfRequested() }
#endif

    // MARK: Tunables (single source of truth for the recall/precision trade-off)

    private enum Tuning {
        /// Snapshot edge length in pixels. 1024 over a ~300–600 m frame is ~0.3–0.6 m/px, enough for
        /// a painted line to register as a 1–2 px brightness ridge.
        static let snapshotPixels: CGFloat = 1024
        /// Zoom-equivalent scales applied to the requested span. 1.0 is the frame as asked; 0.8
        /// zooms IN so a pitch that's small in a wide frame grows past the rectangle detector's
        /// minimum size; 1.35 zooms OUT so a tightly-framed pitch keeps its touchlines inside the
        /// image (VNDetectRectangles won't lock onto edges that run off-frame).
        static let scales: [Double] = [0.8, 1.0, 1.35]

        // Plausible pitch metrics — deliberately wider than the strict soccer-only Kit check so
        // small-sided / training pitches are still recalled. Precision comes from the grass + line
        // scoring, not from a narrow size gate.
        static let minLengthMeters = 40.0
        static let maxLengthMeters = 135.0
        static let minWidthMeters = 20.0
        static let maxWidthMeters = 95.0
        static let minAspect = 1.15
        static let maxAspect = 3.2

        // Scoring weights (sum ≈ 1).
        static let lineWeight = 0.45
        static let grassWeight = 0.35
        static let aspectWeight = 0.20

        // Gates. The grass gate is the primary precision lever: a real pitch interior is grass
        // throughout (~0.8+), whereas a rectangle that Vision fits to a bright rooftop only picks up
        // grass where it spills onto surrounding vegetation (~0.4–0.5), so a firm 0.6 gate rejects
        // rooftops/parking without hurting worn-turf recall.
        static let minGrassFraction = 0.60   // grass-dominant interior
        static let minLineFraction = 0.15    // some touchline evidence
        static let minScore = 0.34

        // Non-max suppression IoU above which the lower-scoring candidate is dropped.
        static let suppressionIoU = 0.30
    }

    /// Detect candidate pitches in a map region (e.g. the visible viewport).
    func detectFields(in region: MKCoordinateRegion) async -> [OrientedRectangle] {
        let proposals = await analyzeMultiScale(region: region)
        return nonMaxSuppressed(proposals)
            .sorted { $0.score > $1.score }
            .map(\.rectangle)
    }

    /// Scan around an existing (GPS-inferred) rectangle and return a crisp satellite rectangle
    /// overlapping it by >= 70%, used to sharpen noisy GPS geometry.
    func snap(rectangle: OrientedRectangle) async -> OrientedRectangle? {
        let region = scanRegion(around: rectangle)
        let candidates = await analyzeMultiScale(region: region).map(\.rectangle)
        return candidates
            .filter { overlapFraction(between: $0, and: rectangle) >= 0.7 }
            .max { overlapFraction(between: $0, and: rectangle) < overlapFraction(between: $1, and: rectangle) }
    }

    // MARK: - Snapshot

    struct Snapshot {
        let mkSnapshot: MKMapSnapshotter.Snapshot
        let sampler: PixelSampler
        let region: MKCoordinateRegion
    }

    /// Snapshot a region. Exposed (internal) so the DEBUG validation harness can render the same
    /// imagery the detector scans.
    func snapshot(of region: MKCoordinateRegion) async throws -> Snapshot {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: Tuning.snapshotPixels, height: Tuning.snapshotPixels)
        options.preferredConfiguration = MKImageryMapConfiguration()

        let snapshotter = MKMapSnapshotter(options: options)
        let mkSnapshot: MKMapSnapshotter.Snapshot = try await withCheckedThrowingContinuation { continuation in
            snapshotter.start { snapshot, error in
                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
        guard let sampler = PixelSampler(image: mkSnapshot.image) else {
            throw CocoaError(.featureUnsupported)
        }
        return Snapshot(mkSnapshot: mkSnapshot, sampler: sampler, region: region)
    }

    // MARK: - Multi-scale sweep

    private func analyzeMultiScale(region: MKCoordinateRegion) async -> [Proposal] {
        // Snapshot + analyse every scale CONCURRENTLY — the per-scale snapshot (a network tile
        // fetch) dominates wall-clock time, so running them in parallel keeps a full multi-scale
        // sweep well under the ~3s budget instead of paying for each scale serially.
        await withTaskGroup(of: [Proposal].self) { group in
            for scale in Tuning.scales {
                let scaled = MKCoordinateRegion(
                    center: region.center,
                    span: MKCoordinateSpan(
                        latitudeDelta: region.span.latitudeDelta * scale,
                        longitudeDelta: region.span.longitudeDelta * scale
                    )
                )
                group.addTask {
                    guard !Task.isCancelled, let snapshot = try? await self.snapshot(of: scaled),
                          !Task.isCancelled else { return [] }
                    return self.analyze(snapshot: snapshot)
                }
            }
            var all: [Proposal] = []
            for await proposals in group { all.append(contentsOf: proposals) }
            return all
        }
    }

    // MARK: - Analysis

    /// Run the candidate generator + scoring over a single snapshot. Internal so the DEBUG harness
    /// can report per-snapshot detail.
    func analyze(snapshot: Snapshot) -> [Proposal] {
        guard let ciImage = CIImage(image: snapshot.mkSnapshot.image) else { return [] }
        let imageSize = snapshot.mkSnapshot.image.size

        var normalizedQuads = rectangleCandidates(in: ciImage)
        normalizedQuads += rectangleCandidates(in: lineEnhanced(ciImage))

        var proposals: [Proposal] = []
        for quad in normalizedQuads {
            // Vision normalized points use a bottom-left origin; convert to top-left image points.
            let visionImagePoints = quad.map { point in
                CGPoint(x: point.x * imageSize.width, y: (1 - point.y) * imageSize.height)
            }
            let coordinates = visionImagePoints.map { pixelToCoordinate($0, snapshot: snapshot) }
            guard let rectangle = FieldGeometry.fitOrientedRectangle(to: coordinates),
                  plausibleDimensions(rectangle) else { continue }

            // Score against the CLEAN fitted rectangle edges (projected back to image space), so line
            // evidence is measured along straight touchlines rather than Vision's slightly ragged quad.
            let edgePoints = rectangle.corners.map { snapshot.mkSnapshot.point(for: $0.clCoordinate) }
            let evaluation = evaluate(edgeImagePoints: edgePoints, sampler: snapshot.sampler, rectangle: rectangle)
            guard evaluation.passes else { continue }
            proposals.append(Proposal(rectangle: rectangle, score: evaluation.score))
        }
        return proposals
    }

    /// Quadrilateral candidates as normalized (bottom-left origin) corner rings.
    private func rectangleCandidates(in image: CIImage) -> [[CGPoint]] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 32
        request.minimumConfidence = 0.0
        request.minimumAspectRatio = 0.25   // allow elongated pitches (short:long down to 1:4)
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.06          // as small as ~6% of the frame (the metric gate rejects tiny quads)
        request.quadratureTolerance = 40    // tolerate perspective / imperfect corners
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        return results.map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] }
    }

    /// Amplify thin bright markings relative to their surroundings so the rectangle detector can
    /// lock onto faint / worn touchlines. Desaturate first (colour carries no line information),
    /// then unsharp-mask to boost the ridge, then restore contrast.
    private func lineEnhanced(_ image: CIImage) -> CIImage {
        let mono = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.15
        ])
        return mono.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2.5,
            kCIInputIntensityKey: 2.0
        ])
    }

    // MARK: - Plausibility

    private func plausibleDimensions(_ rectangle: OrientedRectangle) -> Bool {
        let length = rectangle.lengthMeters
        let width = rectangle.widthMeters
        guard width > 0 else { return false }
        let aspect = length / width
        return length >= Tuning.minLengthMeters && length <= Tuning.maxLengthMeters
            && width >= Tuning.minWidthMeters && width <= Tuning.maxWidthMeters
            && aspect >= Tuning.minAspect && aspect <= Tuning.maxAspect
    }

    // MARK: - Scoring

    struct Evaluation {
        var score: Double
        var lineFraction: Double
        var grassFraction: Double
        var aspectPrior: Double
        var passes: Bool
    }

    /// Score a candidate. `edgeImagePoints` are the fitted rectangle's four corners in image space
    /// (top-left origin), in ring order. Internal so the DEBUG harness can log the breakdown.
    func evaluate(edgeImagePoints: [CGPoint], sampler: PixelSampler, rectangle: OrientedRectangle) -> Evaluation {
        let line = perimeterLineSupport(corners: edgeImagePoints, sampler: sampler)
        let grassFraction = interiorGrassFraction(corners: edgeImagePoints, sampler: sampler)
        let aspectPrior = aspectPrior(for: rectangle)

        let score = Tuning.lineWeight * line.fraction
            + Tuning.grassWeight * grassFraction
            + Tuning.aspectWeight * aspectPrior

        // A pitch is boxed by touchlines on multiple sides. Requiring markings on ≥2 of the 4 edges
        // rejects a grass strip that merely borders a bright concrete curb/road on a single side
        // (one white-ish edge is not a pitch), while staying tolerant enough not to drop a real pitch
        // whose far touchlines are faint or partly shadowed.
        let passes = grassFraction >= Tuning.minGrassFraction
            && line.fraction >= Tuning.minLineFraction
            && line.supportedEdges >= 2
            && score >= Tuning.minScore
        return Evaluation(score: score, lineFraction: line.fraction, grassFraction: grassFraction,
                          aspectPrior: aspectPrior, passes: passes)
    }

    /// Fraction of samples along the rectangle perimeter that sit on a painted-line ridge. A pitch
    /// marking is (a) brighter than the turf a few pixels to either side AND (b) *whiter* — less
    /// saturated — than that turf, because chalk/paint reads closer to neutral than grass does. Both
    /// tests are LOCAL and relative, so faint chalk over worn brown grass still fires where an
    /// absolute white threshold never would, while crop rows and dry-grass streaks (which stay as
    /// saturated as their surroundings) do NOT — that whiteness test is what rejects farmland and
    /// featureless practice grass. The perpendicular search window (±`ridgeSearch` px) absorbs the
    /// small offset between Vision's edge and the painted line.
    private func perimeterLineSupport(corners: [CGPoint], sampler: PixelSampler)
        -> (fraction: Double, supportedEdges: Int) {
        guard corners.count == 4 else { return (0, 0) }
        let center = centroid(of: corners)
        let ridgeSearch = 5          // px, half-window searched perpendicular for the brightest ridge
        let shoulder = 6.0           // px, how far out the turf "shoulders" are compared against
        let brightnessMargin = 0.05  // brightness the ridge must exceed the shoulders by
        // A real marking is near-WHITE: absolutely light and genuinely low-saturation (paint/chalk),
        // not merely a slightly-brighter, slightly-less-green patch. These absolute floors are what
        // separate a painted touchline from a farmland mowing stripe or a dry-grass streak, which
        // stay green/tan (higher saturation) even where they brighten.
        let minRidgeBrightness = 0.50
        let maxRidgeSaturation = 0.18
        let whitenessMargin = 0.02   // and still measurably whiter than the flanking turf

        let edgeSupportThreshold = 0.20  // per-edge hit fraction for an edge to count as "marked"
        var hits = 0.0
        var samples = 0.0
        var supportedEdges = 0
        for edge in 0..<4 {
            var edgeHits = 0.0
            var edgeSamples = 0.0
            let a = corners[edge]
            let b = corners[(edge + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(6, min(40, Int(length / 12)))
            // Inward-facing unit normal (toward the rectangle centre).
            var normal = CGPoint(x: -(b.y - a.y), y: b.x - a.x)
            let normalLength = hypot(normal.x, normal.y)
            guard normalLength > 0 else { continue }
            normal = CGPoint(x: normal.x / normalLength, y: normal.y / normalLength)
            let midEdge = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if dot(CGPoint(x: center.x - midEdge.x, y: center.y - midEdge.y), normal) < 0 {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }

            for step in 1..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                let base = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                samples += 1
                edgeSamples += 1

                // Find the brightest point within the perpendicular search window around the edge.
                var ridge: (brightness: Double, saturation: Double)?
                var ridgeOffset = 0.0
                for offset in -ridgeSearch...ridgeSearch {
                    let p = CGPoint(x: base.x + normal.x * CGFloat(offset),
                                    y: base.y + normal.y * CGFloat(offset))
                    guard let sample = sampler.brightnessAndSaturation(at: p) else { continue }
                    if ridge == nil || sample.brightness > ridge!.brightness {
                        ridge = sample; ridgeOffset = Double(offset)
                    }
                }
                guard let ridge else { continue }

                // Compare against the turf shoulders just inside and outside the ridge.
                let inner = sampler.brightnessAndSaturation(at: CGPoint(
                    x: base.x + normal.x * CGFloat(ridgeOffset + shoulder),
                    y: base.y + normal.y * CGFloat(ridgeOffset + shoulder)))
                let outer = sampler.brightnessAndSaturation(at: CGPoint(
                    x: base.x + normal.x * CGFloat(ridgeOffset - shoulder),
                    y: base.y + normal.y * CGFloat(ridgeOffset - shoulder)))
                guard let inner, let outer else { continue }
                let brighter = ridge.brightness - max(inner.brightness, outer.brightness) > brightnessMargin
                let white = ridge.brightness > minRidgeBrightness && ridge.saturation < maxRidgeSaturation
                let whiter = ridge.saturation + whitenessMargin < max(inner.saturation, outer.saturation)
                if brighter && white && whiter { hits += 1; edgeHits += 1 }
            }
            if edgeSamples > 0 && edgeHits / edgeSamples >= edgeSupportThreshold { supportedEdges += 1 }
        }
        return (samples > 0 ? hits / samples : 0, supportedEdges)
    }

    /// Fraction of interior samples that read as field surface under a wide, hue-tolerant grass
    /// band (vivid green through yellow-green to worn brown, including shadowed turf).
    private func interiorGrassFraction(corners: [CGPoint], sampler: PixelSampler) -> Double {
        guard corners.count == 4 else { return 0 }
        let center = centroid(of: corners)
        var total = 0.0
        var samples = 0.0
        // Sample a grid biased toward the interior (0.7 inset) so touchlines and adjacent surfaces
        // outside the pitch don't pollute the turf estimate.
        for u in stride(from: -0.7, through: 0.7, by: 0.2) {
            for v in stride(from: -0.7, through: 0.7, by: 0.2) {
                // Bilinear interior point from the centre toward each corner.
                let point = interiorPoint(corners: corners, center: center, u: u, v: v)
                guard let rgb = sampler.rgb(at: point) else { continue }
                total += fieldLikelihood(r: rgb.r, g: rgb.g, b: rgb.b)
                samples += 1
            }
        }
        return samples > 0 ? total / samples : 0
    }

    /// A point inside the quad, parameterised by (u, v) in [-1, 1] from the centre.
    private func interiorPoint(corners: [CGPoint], center: CGPoint, u: Double, v: Double) -> CGPoint {
        // Average the two edge directions so the sampling grid follows the rectangle's orientation.
        let right = CGPoint(x: (corners[1].x - corners[0].x + corners[2].x - corners[3].x) / 4,
                            y: (corners[1].y - corners[0].y + corners[2].y - corners[3].y) / 4)
        let down = CGPoint(x: (corners[3].x - corners[0].x + corners[2].x - corners[1].x) / 4,
                           y: (corners[3].y - corners[0].y + corners[2].y - corners[1].y) / 4)
        return CGPoint(x: center.x + right.x * u + down.x * v,
                       y: center.y + right.y * u + down.y * v)
    }

    /// Soft field-surface likelihood (0…1) from RGB, tolerant of worn/brown turf and shadow while
    /// rejecting water (blue-dominant), asphalt/concrete (near-neutral grey) and rooftops.
    private func fieldLikelihood(r: Double, g: Double, b: Double) -> Double {
        let brightness = (r + g + b) / 3
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
        let excessGreen = 2 * g - r - b

        // Blue/cyan dominant with real saturation → water or a hard court.
        if b > r && b > g && saturation > 0.12 { return 0 }
        // Clear vegetation.
        if excessGreen > 0.06 { return 1.0 }
        // Yellow-green / mixed turf (green still at least ties blue).
        if excessGreen > -0.02 && g >= b { return 0.8 }
        // Warm, dry / worn grass: red≥green≥blue but not strongly red, mid brightness.
        if r >= g && g >= b && (r - g) < 0.22 && brightness > 0.18 && brightness < 0.80 { return 0.6 }
        // Near-neutral grey (asphalt, concrete, rooftops) — very unlikely to be turf.
        if saturation < 0.06 { return 0.05 }
        return 0.15
    }

    /// Aspect-ratio prior, peaked near a full-size pitch (~1.5) but broad enough to keep
    /// small-sided (~1.2) and wide (~2.0) pitches.
    private func aspectPrior(for rectangle: OrientedRectangle) -> Double {
        guard rectangle.widthMeters > 0 else { return 0 }
        let aspect = rectangle.lengthMeters / rectangle.widthMeters
        let sigma = 0.6
        let delta = aspect - 1.5
        return exp(-(delta * delta) / (2 * sigma * sigma))
    }

    // MARK: - Non-max suppression

    private func nonMaxSuppressed(_ proposals: [Proposal]) -> [Proposal] {
        let sorted = proposals.sorted { $0.score > $1.score }
        var kept: [Proposal] = []
        for candidate in sorted {
            let overlapsKept = kept.contains { existing in
                overlapFraction(between: existing.rectangle, and: candidate.rectangle) > Tuning.suppressionIoU
            }
            if !overlapsKept { kept.append(candidate) }
        }
        return kept
    }

    // MARK: - Small vector helpers

    private func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let count = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / count,
                       y: points.reduce(0) { $0 + $1.y } / count)
    }

    private func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }

    // MARK: - Coordinate mapping

    private func pixelToCoordinate(_ point: CGPoint, snapshot: Snapshot) -> Coordinate2D {
        let region = snapshot.region
        let topLeft = CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let bottomRight = CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )
        let pTopLeft = snapshot.mkSnapshot.point(for: topLeft)
        let pBottomRight = snapshot.mkSnapshot.point(for: bottomRight)

        let dx = pBottomRight.x - pTopLeft.x
        let dy = pBottomRight.y - pTopLeft.y
        let fx = abs(dx) > 0.0001 ? (point.x - pTopLeft.x) / dx : 0
        let fy = abs(dy) > 0.0001 ? (point.y - pTopLeft.y) / dy : 0

        let longitude = topLeft.longitude + Double(fx) * (bottomRight.longitude - topLeft.longitude)
        let latitude = topLeft.latitude + Double(fy) * (bottomRight.latitude - topLeft.latitude)
        return Coordinate2D(latitude: latitude, longitude: longitude)
    }

    private func scanRegion(around rectangle: OrientedRectangle) -> MKCoordinateRegion {
        let frame = ENUFrame(reference: rectangle.center)
        let padding = rectangle.lengthMeters * 1.6
        return MKCoordinateRegion(
            center: rectangle.center.clCoordinate,
            span: MKCoordinateSpan(
                latitudeDelta: padding / metersPerDegreeLatitude,
                longitudeDelta: padding / max(frame.metersPerDegreeLongitude, 1)
            )
        )
    }

    // MARK: - Overlap (approximate IoU in local ENU meters)

    private func overlapFraction(between a: OrientedRectangle, and b: OrientedRectangle) -> Double {
        let frame = ENUFrame(reference: b.center)
        let quadA = a.corners.map(frame.project)
        let quadB = b.corners.map(frame.project)
        guard quadA.count == 4, quadB.count == 4 else { return 0 }

        let allX = (quadA + quadB).map(\.x)
        let allY = (quadA + quadB).map(\.y)
        guard let minX = allX.min(), let maxX = allX.max(),
              let minY = allY.min(), let maxY = allY.max(), maxX > minX, maxY > minY else { return 0 }

        let steps = 40
        var intersection = 0, union = 0
        for i in 0...steps {
            for j in 0...steps {
                let point = CGPoint(x: minX + (maxX - minX) * CGFloat(i) / CGFloat(steps),
                                    y: minY + (maxY - minY) * CGFloat(j) / CGFloat(steps))
                let inA = pointInQuad(point, quadA)
                let inB = pointInQuad(point, quadB)
                if inA && inB { intersection += 1 }
                if inA || inB { union += 1 }
            }
        }
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private func pointInQuad(_ point: CGPoint, _ quad: [CGPoint]) -> Bool {
        var sign = 0
        for i in 0..<quad.count {
            let a = quad[i]
            let b = quad[(i + 1) % quad.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let current = cross > 0 ? 1 : (cross < 0 ? -1 : 0)
            if current != 0 {
                if sign == 0 { sign = current }
                else if sign != current { return false }
            }
        }
        return true
    }
}

/// Reads RGBA pixels from a snapshot image for line/turf scoring.
struct PixelSampler {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let pixels: [UInt8]

    init?(image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        width = cgImage.width
        height = cgImage.height
        bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = buffer
    }

    /// RGB (0...1) at an image point; the point is in image-point space (top-left origin).
    func rgb(at point: CGPoint) -> (r: Double, g: Double, b: Double)? {
        let x = Int(point.x)
        let y = Int(point.y)
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = y * bytesPerRow + x * 4
        return (Double(pixels[offset]) / 255,
                Double(pixels[offset + 1]) / 255,
                Double(pixels[offset + 2]) / 255)
    }

    /// Mean-channel brightness and HSV saturation (both 0...1) at an image point, or nil if out of
    /// bounds. Saturation lets line scoring tell whitish paint from equally-bright but still-green
    /// grass/crop texture.
    func brightnessAndSaturation(at point: CGPoint) -> (brightness: Double, saturation: Double)? {
        guard let rgb = rgb(at: point) else { return nil }
        let maxC = max(rgb.r, max(rgb.g, rgb.b))
        let minC = min(rgb.r, min(rgb.g, rgb.b))
        let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
        return ((rgb.r + rgb.g + rgb.b) / 3, saturation)
    }
}
