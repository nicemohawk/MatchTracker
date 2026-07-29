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
        /// image (VNDetectRectangles won't lock onto edges that run off-frame, and the ridge search
        /// frames a pitch more reliably once its whole outline is visible).
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
        /// Interior brightness std-dev ceiling. A smooth playing surface (worn or lush) stays well
        /// below this; tree canopy, a car-filled parking lot and rooftops sit above it. Calibrated so
        /// real pitches pass with margin while the vegetation/parking clutter that reads as green is cut.
        static let maxInteriorRoughness = 0.135

        // Non-max suppression IoU above which the lower-scoring candidate is dropped.
        static let suppressionIoU = 0.30
    }

    /// Detect candidate pitches in a map region (e.g. the visible viewport).
    func detectFields(in region: MKCoordinateRegion) async -> [OrientedRectangle] {
        let spanMeters = Int(region.span.latitudeDelta * 111_320)
        MatchLog.info("scan: starting over ~\(spanMeters) m span", category: "scan")
        let proposals = await analyzeMultiScale(region: region)
        let survivors = nonMaxSuppressed(proposals).sorted { $0.score > $1.score }
        if let best = survivors.first {
            MatchLog.info(String(format: "scan: %d raw candidates → %d after NMS; best %.0f×%.0f m score %.2f",
                                 proposals.count, survivors.count,
                                 best.rectangle.lengthMeters, best.rectangle.widthMeters, best.score),
                          category: "scan")
        } else {
            MatchLog.info("scan: \(proposals.count) raw candidates, none survived gating/NMS",
                          category: "scan")
        }
        return survivors.map(\.rectangle)
    }

    /// Scan around an existing (GPS-inferred) rectangle and return a crisp satellite rectangle
    /// overlapping it by >= 70%, used to sharpen noisy GPS geometry.
    func snap(rectangle: OrientedRectangle) async -> OrientedRectangle? {
        let region = scanRegion(around: rectangle)
        let candidates = await analyzeMultiScale(region: region).map(\.rectangle)
        let snapped = candidates
            .filter { overlapFraction(between: $0, and: rectangle) >= 0.7 }
            .max { overlapFraction(between: $0, and: rectangle) < overlapFraction(between: $1, and: rectangle) }
        if let snapped {
            MatchLog.info(String(format: "scan: snapped GPS fit to satellite rectangle %.0f×%.0f m (overlap %.0f%%)",
                                 snapped.lengthMeters, snapped.widthMeters,
                                 overlapFraction(between: snapped, and: rectangle) * 100),
                          category: "scan")
        } else {
            MatchLog.info("scan: snap found no satellite rectangle overlapping the GPS fit (\(candidates.count) candidates)",
                          category: "scan")
        }
        return snapped
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

    /// Run the candidate generators + scoring over a single snapshot. Internal so the DEBUG harness
    /// can report per-snapshot detail.
    ///
    /// TWO candidate generators feed one scorer:
    ///  • Vision (`VNDetectRectanglesRequest`) — wins on crisp, high-contrast complexes where the
    ///    quad is obvious, but keys on strong edge gradients and so returns NOTHING for a faint chalk
    ///    outline on worn/textured grass (the real failure the field report hit).
    ///  • A model-driven RIDGE SEARCH (`ridgeSearchImageQuads`) — estimates the pitch's line
    ///    orientation from the whole-frame white-paint ridge map, then sweeps oriented rectangles
    ///    aligned to it and hill-climbs the best ones onto the markings. This recovers exactly the
    ///    faint / edge-of-frame pitches Vision misses.
    /// Both emit image-space (top-left origin) quads; a single `proposal(imageQuad:)` path scores and
    /// GATES every candidate identically, so precision is governed by one scorer regardless of source.
    func analyze(snapshot: Snapshot) -> [Proposal] {
        guard let ciImage = CIImage(image: snapshot.mkSnapshot.image) else { return [] }
        let imageSize = snapshot.mkSnapshot.image.size

        // Vision candidates (raw + line-enhanced), converted from normalized bottom-left to image points.
        var imageQuads = visionImageQuads(in: ciImage, imageSize: imageSize)
        imageQuads += visionImageQuads(in: lineEnhanced(ciImage), imageSize: imageSize)

        var proposals: [Proposal] = []
        // Vision candidates: gate with the shared scorer only (these are already tightly framed).
        for quad in imageQuads {
            if let proposal = proposal(imageQuad: quad, snapshot: snapshot, enforceRoughness: false) {
                proposals.append(proposal)
            }
        }
        // Model-driven candidates from the white-line ridge map, each snapped onto the touchlines by a
        // final alignment against the real scorer, then gated with the extra ridge precision check.
        let maps = RidgeMaps(sampler: snapshot.sampler, imageSize: imageSize)
        for hypothesis in ridgeSearchHypotheses(maps: maps, imageSize: imageSize) {
            let quad = alignToScorer(hypothesis, snapshot: snapshot).corners()
            if let proposal = proposal(imageQuad: quad, snapshot: snapshot, enforceRoughness: true) {
                proposals.append(proposal)
            }
        }
        return proposals
    }

#if DEBUG
    /// DEBUG-only introspection of the ridge-search path for one snapshot: how many oriented
    /// candidates it produced and, for the strongest few, the fit + gate breakdown. Lets the
    /// validation harness show WHY a worn pitch did/didn't survive without a rebuild-per-guess loop.
    func ridgeSearchDiagnostics(snapshot: Snapshot) -> String {
        guard let ciImage = CIImage(image: snapshot.mkSnapshot.image) else { return "no-ci" }
        let imageSize = snapshot.mkSnapshot.image.size
        let maps = RidgeMaps(sampler: snapshot.sampler, imageSize: imageSize)
        let orientationDegrees = dominantOrientations(maps: maps).map { Int(($0 * 180 / .pi).rounded()) % 180 }
        let hypotheses = ridgeSearchHypotheses(maps: maps, imageSize: imageSize)
            .map { alignToScorer($0, snapshot: snapshot) }
        var lines = ["orient=\(orientationDegrees) ridgeQuads=\(hypotheses.count)"]
        for hypothesis in hypotheses.prefix(5) {
            let coordinates = hypothesis.corners().map { pixelToCoordinate($0, snapshot: snapshot) }
            guard let rectangle = FieldGeometry.fitOrientedRectangle(to: coordinates) else {
                lines.append("fit-fail"); continue
            }
            let plausible = plausibleDimensions(rectangle)
            let edgePoints = rectangle.corners.map { snapshot.mkSnapshot.point(for: $0.clCoordinate) }
            let evaluation = evaluate(edgeImagePoints: edgePoints, sampler: snapshot.sampler, rectangle: rectangle)
            let aspect = rectangle.lengthMeters / max(rectangle.widthMeters, 1)
            lines.append(String(format: "L%.0f×W%.0f a%.2f plaus=%@ grass%.2f line%.2f e%d rgh%.3f s%.2f pass=%@",
                rectangle.lengthMeters, rectangle.widthMeters, aspect, plausible ? "Y" : "N",
                evaluation.grassFraction, evaluation.lineFraction, evaluation.supportedEdges,
                evaluation.roughness, evaluation.score, evaluation.passes ? "Y" : "N"))
        }
        return lines.joined(separator: " | ")
    }

    /// DEBUG-only: the fitted rectangles for the ridge search's refined candidates BEFORE gating, so
    /// the harness can draw where the model-driven search actually landed (pass or fail).
    func ridgeSearchDebugRectangles(snapshot: Snapshot) -> [OrientedRectangle] {
        guard let ciImage = CIImage(image: snapshot.mkSnapshot.image) else { return [] }
        let imageSize = snapshot.mkSnapshot.image.size
        let maps = RidgeMaps(sampler: snapshot.sampler, imageSize: imageSize)
        return ridgeSearchHypotheses(maps: maps, imageSize: imageSize).compactMap { hypothesis in
            let aligned = alignToScorer(hypothesis, snapshot: snapshot)
            return FieldGeometry.fitOrientedRectangle(to: aligned.corners().map { pixelToCoordinate($0, snapshot: snapshot) })
        }
    }
#endif

    /// Vision rectangle candidates as image-space (top-left origin) corner rings.
    private func visionImageQuads(in image: CIImage, imageSize: CGSize) -> [[CGPoint]] {
        rectangleCandidates(in: image).map { quad in
            // Vision normalized points use a bottom-left origin; convert to top-left image points.
            quad.map { CGPoint(x: $0.x * imageSize.width, y: (1 - $0.y) * imageSize.height) }
        }
    }

    /// Fit → plausibility → score → gate one image-space candidate quad. Returns a scored proposal
    /// only if it clears the precision gates. Shared by BOTH candidate generators; `enforceRoughness`
    /// adds the ridge-only interior-texture gate.
    private func proposal(imageQuad points: [CGPoint], snapshot: Snapshot, enforceRoughness: Bool) -> Proposal? {
        guard points.count == 4 else { return nil }
        let coordinates = points.map { pixelToCoordinate($0, snapshot: snapshot) }
        guard let rectangle = FieldGeometry.fitOrientedRectangle(to: coordinates),
              plausibleDimensions(rectangle) else { return nil }

        // Score against the CLEAN fitted rectangle edges (projected back to image space), so line
        // evidence is measured along straight touchlines rather than a slightly ragged candidate quad.
        let edgePoints = rectangle.corners.map { snapshot.mkSnapshot.point(for: $0.clCoordinate) }
        let evaluation = evaluate(edgeImagePoints: edgePoints, sampler: snapshot.sampler, rectangle: rectangle)
        guard evaluation.passes else { return nil }
        if enforceRoughness && !passesRidgePrecisionGate(evaluation) { return nil }
        return Proposal(rectangle: rectangle, score: evaluation.score)
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

    // MARK: - Ridge search (model-driven candidate generator)
    //
    // Vision needs a strong quad to lock onto; a faint chalk outline on worn grass produces none, so
    // the scorer never gets a candidate to score. This generator inverts the problem: it reads the
    // white-line evidence FIRST (a coarse ridge map over the whole frame), estimates the pitch's grid
    // orientation from it, then proposes oriented rectangles aligned to that grid and hill-climbs the
    // strongest ones onto the markings. It hands well-framed quads to the SAME scorer/gates as Vision,
    // so it only adds recall — precision is still owned by `evaluate`.

    private enum RidgeTuning {
        /// Downsampled grid resolution for the coarse ridge/grass maps (cells per side). 256 over a
        /// 1024 px frame is a 4 px cell — fine enough to register a painted line, coarse enough that a
        /// full frame-wide sweep of oriented rectangles stays well inside the time budget.
        static let gridResolution = 256
        /// Coarse-search center grid: fractional positions across the frame (biased away from the very
        /// edge where a pitch can't be fully framed). Hill-climb reaches between grid points, so a
        /// modest grid suffices and keeps a full-frame sweep well inside the time budget.
        static let centerFractions: [CGFloat] = [0.22, 0.36, 0.50, 0.64, 0.78]
        /// Candidate long-side lengths as a fraction of the frame — 45–95% covers a pitch that fills
        /// most of the view (the field-report case) down to a smaller pitch inside a wider frame.
        static let lengthFractions: [CGFloat] = [0.45, 0.60, 0.75, 0.90]
        /// Candidate aspect ratios (long:short). Hill-climb + the metric plausibility gate cover the rest.
        static let aspects: [CGFloat] = [1.30, 1.50, 1.70]
        /// How many coarse candidates to hill-climb, and how many refined quads to hand to the scorer.
        static let refineCount = 12
        static let outputCount = 10
        /// Coarse pre-filter: interior grass floor to survive into ranking (keeps the search off
        /// parking lots / rooftops before the expensive full scorer ever runs).
        static let minCoarseGrass = 0.50
    }

    /// Downsampled per-cell maps over one snapshot: `white` ≈ painted-line likeness (bright AND
    /// low-saturation), `grass` = field-surface likelihood. Addressed in image-point space to match
    /// the sampler convention the rest of the detector uses.
    struct RidgeMaps {
        let grid: Int
        let cell: CGFloat            // image points per grid cell
        let imageSize: CGSize
        private let white: [Float]
        private let grass: [Float]

        init(sampler: PixelSampler, imageSize: CGSize) {
            let grid = RidgeTuning.gridResolution
            self.grid = grid
            self.imageSize = imageSize
            self.cell = imageSize.width / CGFloat(grid)
            var white = [Float](repeating: 0, count: grid * grid)
            var grass = [Float](repeating: 0, count: grid * grid)
            // Painted markings are a LOCAL brightness ridge: a line pixel is brighter (and whiter/less
            // saturated) than the turf a few px to either side — but NOT necessarily bright in absolute
            // terms. Faint chalk on worn tan grass fails an absolute white threshold yet still stands
            // proud of its immediate surroundings, so we score each cell by that local relief instead.
            // `shoulder` is how far out (image px) the flanking turf is compared against.
            let shoulder: CGFloat = 5
            let cellPx = imageSize.width / CGFloat(grid)
            for gj in 0..<grid {
                for gi in 0..<grid {
                    let baseX = (CGFloat(gi) + 0.5) * cellPx
                    let baseY = (CGFloat(gj) + 0.5) * (imageSize.height / CGFloat(grid))
                    if let rgb = sampler.rgb(at: CGPoint(x: baseX, y: baseY)) {
                        grass[gj * grid + gi] = Float(SatelliteFieldDetector.staticFieldLikelihood(r: rgb.r, g: rgb.g, b: rgb.b))
                    }
                    // A painted line is ~1 px wide but a grid cell spans several px, so sampling only the
                    // cell centre would MISS most of the line (it registers only where the line happens
                    // to cross a centre) and render markings as dotted, undervaluing a real outline. Take
                    // the MAX relief over a 3×3 sub-grid inside the cell so every cell the line touches
                    // lights up — sampling is just array indexing, so this stays cheap.
                    var maxRelief = 0.0
                    for (sx, sy) in [(0.0, 0.0), (-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5)] {
                        let x = baseX + CGFloat(sx)
                        let y = baseY + CGFloat(sy)
                        guard let center = sampler.brightnessAndSaturation(at: CGPoint(x: x, y: y)),
                              center.brightness > 0.32 else { continue }
                        let left = sampler.brightnessAndSaturation(at: CGPoint(x: x - shoulder, y: y))
                        let right = sampler.brightnessAndSaturation(at: CGPoint(x: x + shoulder, y: y))
                        let up = sampler.brightnessAndSaturation(at: CGPoint(x: x, y: y - shoulder))
                        let down = sampler.brightnessAndSaturation(at: CGPoint(x: x, y: y + shoulder))
                        // Vertical line → bright centre vs darker left/right (horizontal relief);
                        // horizontal line → relief up/down. A marking of EITHER orientation registers.
                        let relief = max(Self.ridgeRelief(center: center, a: left, b: right),
                                         Self.ridgeRelief(center: center, a: up, b: down))
                        maxRelief = max(maxRelief, relief)
                    }
                    // GRASS-MASK the line response: a pitch marking has turf immediately beside it, a
                    // parking-lot stripe / roofline / cart-path edge has asphalt or water. Sampling the
                    // grass a short way out on all four sides and keeping the response only where turf
                    // flanks the ridge erases crisp NON-pitch lines — the parking stripes and path edges
                    // that were out-shining faint chalk and dragging the search off the field entirely.
                    // Use the MEAN grass over all four flanks, not the max: a pitch marking is
                    // surrounded by turf on every side, whereas a parking stripe (even one near the lot's
                    // grass margin) or a path edge has asphalt on at least one side, dropping the mean.
                    // This is what finally erases dense parking-lot stripe fields that a one-sided test
                    // let through and that kept out-competing the faint pitch.
                    let flank: CGFloat = 11
                    var flankSum = 0.0
                    var flankTaps = 0.0
                    for (fx, fy) in [(-flank, 0), (flank, 0), (0, -flank), (0, flank)] {
                        if let rgb = sampler.rgb(at: CGPoint(x: baseX + fx, y: baseY + CGFloat(fy))) {
                            flankSum += SatelliteFieldDetector.staticFieldLikelihood(r: rgb.r, g: rgb.g, b: rgb.b)
                            flankTaps += 1
                        }
                    }
                    let flankGrass = flankTaps > 0 ? flankSum / flankTaps : 0
                    let grassMask = min(1.0, max(0.0, (flankGrass - 0.45) / 0.30))
                    white[gj * grid + gi] = Float(min(1.0, maxRelief / 0.12) * grassMask)
                }
            }
            self.white = white
            self.grass = grass
        }

        /// Local line relief at a cell: how much brighter AND whiter (less saturated) the center is
        /// than the brighter of its two flanking shoulders. Positive only for a genuine bright, near-
        /// neutral ridge, so dry-grass streaks (which brighten but stay saturated) score ~0. Mirrors
        /// the relative test in `perimeterLineSupport`, just computed omnidirectionally for the map.
        private static func ridgeRelief(center: (brightness: Double, saturation: Double),
                                        a: (brightness: Double, saturation: Double)?,
                                        b: (brightness: Double, saturation: Double)?) -> Double {
            guard let a, let b else { return 0 }
            let brighter = center.brightness - max(a.brightness, b.brightness)
            let whiter = max(a.saturation, b.saturation) - center.saturation
            guard brighter > 0, whiter > -0.02 else { return 0 }
            // Fold in a gentle whiteness factor so a bright-but-still-green bump is discounted.
            return brighter * min(1.0, max(0.25, (whiter + 0.06) / 0.12))
        }

        func whiteAt(_ point: CGPoint) -> Float { self[point.x, point.y, white] }
        func grassAt(_ point: CGPoint) -> Float { self[point.x, point.y, grass] }

        private subscript(_ px: CGFloat, _ py: CGFloat, _ map: [Float]) -> Float {
            let gi = Int(px / cell)
            let gj = Int(py / cell)
            guard gi >= 0, gi < grid, gj >= 0, gj < grid else { return 0 }
            return map[gj * grid + gi]
        }
    }

    /// One oriented-rectangle hypothesis in image-point space. `angle` is the long-axis bearing in
    /// image coordinates (x right, y down), radians.
    private struct RectHypothesis {
        var center: CGPoint
        var halfLength: CGFloat
        var halfWidth: CGFloat
        var angle: CGFloat
        var score: Double

        func corners() -> [CGPoint] {
            let u = CGPoint(x: cos(angle), y: sin(angle))
            let v = CGPoint(x: -sin(angle), y: cos(angle))
            func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
                CGPoint(x: center.x + u.x * a + v.x * b, y: center.y + u.y * a + v.y * b)
            }
            return [point(-halfLength, -halfWidth), point(halfLength, -halfWidth),
                    point(halfLength, halfWidth), point(-halfLength, halfWidth)]
        }
    }

    /// Produce model-driven candidate hypotheses (oriented rectangles in image-point space) for one
    /// snapshot, localized + hill-climbed against the coarse ridge map.
    private func ridgeSearchHypotheses(maps: RidgeMaps, imageSize: CGSize) -> [RectHypothesis] {
        let orientations = dominantOrientations(maps: maps)
        guard !orientations.isEmpty else { return [] }
        let frame = imageSize.width

        // Coarse sweep: every orientation × center × length × aspect, cheaply scored off the maps.
        var coarse: [RectHypothesis] = []
        for angle in orientations {
            for fx in RidgeTuning.centerFractions {
                for fy in RidgeTuning.centerFractions {
                    let center = CGPoint(x: fx * frame, y: fy * imageSize.height)
                    // Cheap reject: center must sit on grass, otherwise this whole family is off-pitch.
                    if maps.grassAt(center) < 0.5 { continue }
                    for lengthFraction in RidgeTuning.lengthFractions {
                        let halfLength = 0.5 * lengthFraction * frame
                        for aspect in RidgeTuning.aspects {
                            let halfWidth = halfLength / aspect
                            var hypothesis = RectHypothesis(center: center, halfLength: halfLength,
                                                            halfWidth: halfWidth, angle: angle, score: 0)
                            let coarseScore = coarseScore(hypothesis, maps: maps)
                            // Need a rectangle outline, not one bright edge: require ≥2 supported edges
                            // on grass. The strict per-edge line-fraction gate is still enforced later by
                            // the shared `evaluate` scorer.
                            guard coarseScore.grass >= RidgeTuning.minCoarseGrass,
                                  coarseScore.supportedEdges >= 2 else { continue }
                            hypothesis.score = coarseScore.score
                            coarse.append(hypothesis)
                        }
                    }
                }
            }
        }

        // Refine the strongest coarse hypotheses: a coarse hill-climb for rough localization, then an
        // edge-snap that locks each of the four sides onto its nearest line. Dedupe near-duplicates so
        // the (expensive) real scorer only runs on distinct pitches.
        let topCoarse = Array(coarse.sorted { $0.score > $1.score }.prefix(RidgeTuning.refineCount))
        var refined: [RectHypothesis] = []
        for hypothesis in topCoarse {
            var candidate = hillClimb(hypothesis, maps: maps, frame: frame)
            candidate = snapEdges(candidate, maps: maps)
            candidate.score = coarseScore(candidate, maps: maps).score
            if !refined.contains(where: { near($0, candidate, frame: frame) }) {
                refined.append(candidate)
            }
        }
        return Array(refined.sorted { $0.score > $1.score }.prefix(RidgeTuning.outputCount))
    }

    /// Lock each side of the rectangle onto its nearest line independently. The two length-edges (which
    /// run along the long axis) sweep perpendicular to find the touchlines; the two width-edges sweep
    /// to find the goal lines. Decoupling the four edges snaps a roughly-placed box tightly onto a
    /// complete outline — far more reliable than joint coordinate descent — and, because each edge only
    /// moves when it actually FINDS a line, a box straddling a pond or parking lot (which has no full
    /// on-grass rectangle in the grass-masked map) can't manufacture one.
    private func snapEdges(_ start: RectHypothesis, maps: RidgeMaps) -> RectHypothesis {
        var hypothesis = start
        let searchRange: CGFloat = 18
        let minLineToMove = 0.10   // don't snap an edge to noise: it must find a real line to move
        for _ in 0..<2 {
            let u = CGPoint(x: cos(hypothesis.angle), y: sin(hypothesis.angle))
            let v = CGPoint(x: -sin(hypothesis.angle), y: cos(hypothesis.angle))

            // Coverage of an edge whose midpoint is `mid`, running along `axis` for ±halfSpan.
            func coverage(mid: CGPoint, axis: CGPoint, halfSpan: CGFloat, normal: CGPoint) -> Double {
                let steps = max(6, min(24, Int(halfSpan / 8)))
                var sum = 0.0
                for step in -steps...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let base = CGPoint(x: mid.x + axis.x * t * halfSpan, y: mid.y + axis.y * t * halfSpan)
                    var best = 0.0
                    for offset in stride(from: CGFloat(-2), through: 2, by: 2) {
                        best = max(best, Double(maps.whiteAt(CGPoint(x: base.x + normal.x * offset, y: base.y + normal.y * offset))))
                    }
                    sum += best
                }
                return sum / Double(2 * steps + 1)
            }
            // Best perpendicular offset for one edge; returns (offset, coverage). Offset 0 unless a line
            // is genuinely found within range.
            func bestOffset(signedHalf: CGFloat, alongAxis: CGPoint, normal: CGPoint, halfSpan: CGFloat) -> CGFloat {
                var bestOffset: CGFloat = 0
                var bestCoverage = 0.0
                for delta in stride(from: -searchRange, through: searchRange, by: 2) {
                    let mid = CGPoint(x: hypothesis.center.x + normal.x * (signedHalf + delta),
                                      y: hypothesis.center.y + normal.y * (signedHalf + delta))
                    let cover = coverage(mid: mid, axis: alongAxis, halfSpan: halfSpan, normal: normal)
                    if cover > bestCoverage { bestCoverage = cover; bestOffset = delta }
                }
                return bestCoverage >= minLineToMove ? bestOffset : 0
            }

            // Length edges (run along u) at ±halfWidth along v → snap perpendicular (v) to the touchlines.
            let plusW = hypothesis.halfWidth + bestOffset(signedHalf: hypothesis.halfWidth, alongAxis: u, normal: v, halfSpan: hypothesis.halfLength)
            let minusW = -hypothesis.halfWidth + bestOffset(signedHalf: -hypothesis.halfWidth, alongAxis: u, normal: v, halfSpan: hypothesis.halfLength)
            let newHalfWidth = (plusW - minusW) / 2
            let shiftV = (plusW + minusW) / 2
            // Width edges (run along v) at ±halfLength along u → snap perpendicular (u) to the goal lines.
            let plusL = hypothesis.halfLength + bestOffset(signedHalf: hypothesis.halfLength, alongAxis: v, normal: u, halfSpan: hypothesis.halfWidth)
            let minusL = -hypothesis.halfLength + bestOffset(signedHalf: -hypothesis.halfLength, alongAxis: v, normal: u, halfSpan: hypothesis.halfWidth)
            let newHalfLength = (plusL - minusL) / 2
            let shiftU = (plusL + minusL) / 2

            hypothesis.center = CGPoint(x: hypothesis.center.x + u.x * shiftU + v.x * shiftV,
                                        y: hypothesis.center.y + u.y * shiftU + v.y * shiftV)
            hypothesis.halfLength = max(20, newHalfLength)
            hypothesis.halfWidth = max(14, newHalfWidth)
        }
        return hypothesis
    }

    /// Final image-space alignment of a ridge hypothesis against the ACTUAL scorer (`evaluate`, via
    /// the real sampler), not the coarse map. Coordinate-descent nudges center / size / angle to
    /// maximize the scorer's own line evidence, snapping the box the last few pixels onto the touch-
    /// lines the coarse ridge map located approximately. This is what closes the gap between "roughly
    /// on the pitch" and "tight enough that `perimeterLineSupport` credits ≥2 edges".
    private func alignToScorer(_ start: RectHypothesis, snapshot: Snapshot) -> RectHypothesis {
        func lineScore(_ hypothesis: RectHypothesis) -> Double {
            let coordinates = hypothesis.corners().map { pixelToCoordinate($0, snapshot: snapshot) }
            guard let rectangle = FieldGeometry.fitOrientedRectangle(to: coordinates) else { return -1 }
            let edgePoints = rectangle.corners.map { snapshot.mkSnapshot.point(for: $0.clCoordinate) }
            let evaluation = evaluate(edgeImagePoints: edgePoints, sampler: snapshot.sampler, rectangle: rectangle)
            // Reward line evidence and — weighted heavily — the supported-edge COUNT, because the gate
            // needs ≥2 edges: a framing that catches all four touchlines must beat one that piles a high
            // fraction onto a single edge (e.g. locking a shrunk box onto the halfway line).
            return evaluation.lineFraction + 0.25 * Double(evaluation.supportedEdges)
        }
        // Keep the box PITCH-SHAPED throughout: a candidate can't raise its line score by collapsing
        // width onto a single strong line (halfway line / parking stripe), so to improve it must catch
        // lines on opposing edges — i.e. actually frame the rectangle.
        func aspectOK(_ hypothesis: RectHypothesis) -> Bool {
            let aspect = hypothesis.halfLength / max(hypothesis.halfWidth, 1)
            return aspect >= 1.15 && aspect <= 2.2
        }
        var best = start
        var bestScore = lineScore(best)
        var positionStep: CGFloat = 12
        var sizeStep: CGFloat = 14
        var angleStep = CGFloat(4 * Double.pi / 180)
        for _ in 0..<7 {
            var improved = false
            let candidates: [RectHypothesis] = [
                mutate(best) { $0.center.x += positionStep }, mutate(best) { $0.center.x -= positionStep },
                mutate(best) { $0.center.y += positionStep }, mutate(best) { $0.center.y -= positionStep },
                mutate(best) { $0.halfLength += sizeStep }, mutate(best) { $0.halfLength = max(20, $0.halfLength - sizeStep) },
                mutate(best) { $0.halfWidth += sizeStep }, mutate(best) { $0.halfWidth = max(14, $0.halfWidth - sizeStep) },
                mutate(best) { $0.angle += angleStep }, mutate(best) { $0.angle -= angleStep }
            ]
            for candidate in candidates where aspectOK(candidate) {
                let score = lineScore(candidate)
                if score > bestScore { best = candidate; bestScore = score; improved = true }
            }
            if !improved { positionStep *= 0.5; sizeStep *= 0.5; angleStep *= 0.5 }
        }
        return best
    }

    /// Estimate the pitch's line-grid orientation(s) from the white-ridge map via a gradient-
    /// orientation histogram. A rectangle's two perpendicular line families produce gradients 90°
    /// apart; folding orientation into [0, 90°) collapses both into a single peak = the grid angle.
    /// Returns that peak and its perpendicular (so the long axis can align to either family), plus a
    /// secondary peak if the frame holds pitches at a second orientation.
    private func dominantOrientations(maps: RidgeMaps) -> [CGFloat] {
        let bins = 45                       // 2° resolution over [0, 90)
        var histogram = [Double](repeating: 0, count: bins)
        let grid = maps.grid
        for gj in 1..<(grid - 1) {
            for gi in 1..<(grid - 1) {
                let gx = Double(maps.whiteAt(cellPoint(gi + 1, gj, maps)) - maps.whiteAt(cellPoint(gi - 1, gj, maps)))
                let gy = Double(maps.whiteAt(cellPoint(gi, gj + 1, maps)) - maps.whiteAt(cellPoint(gi, gj - 1, maps)))
                let magnitude = gx * gx + gy * gy
                if magnitude < 0.0004 { continue }   // ignore flat turf
                var degrees = atan2(gy, gx) * 180 / .pi
                degrees = degrees.truncatingRemainder(dividingBy: 90)
                if degrees < 0 { degrees += 90 }
                let bin = min(bins - 1, Int(degrees / 90 * Double(bins)))
                histogram[bin] += sqrt(magnitude)
            }
        }
        // Smooth (circular) so a peak straddling two bins isn't split.
        var smoothed = [Double](repeating: 0, count: bins)
        for i in 0..<bins {
            smoothed[i] = histogram[(i + bins - 1) % bins] + 2 * histogram[i] + histogram[(i + 1) % bins]
        }
        let total = smoothed.reduce(0, +)
        guard total > 0 else { return [0, .pi / 2] }   // no line evidence → axis-aligned fallback

        // Peak-pick with a minimum angular separation.
        var peaks: [(bin: Int, weight: Double)] = []
        for i in 0..<bins where smoothed[i] >= smoothed[(i + bins - 1) % bins] && smoothed[i] >= smoothed[(i + 1) % bins] {
            peaks.append((i, smoothed[i]))
        }
        peaks.sort { $0.weight > $1.weight }

        var orientations: [CGFloat] = []
        for peak in peaks.prefix(2) where peak.weight > total / Double(bins) * 1.5 {
            let theta = CGFloat(Double(peak.bin) / Double(bins) * 90 * .pi / 180)
            orientations.append(theta)
            orientations.append(theta + .pi / 2)   // perpendicular: long axis may run either way
        }
        // If the strongest peak is weak/absent, fall back to a small default set so the sweep still runs.
        if orientations.isEmpty { orientations = [0, .pi / 4, .pi / 2] }
        return Array(orientations.prefix(3))   // bound the sweep cost
    }

    private func cellPoint(_ gi: Int, _ gj: Int, _ maps: RidgeMaps) -> CGPoint {
        CGPoint(x: (CGFloat(gi) + 0.5) * maps.cell, y: (CGFloat(gj) + 0.5) * maps.cell)
    }

    /// Cheap map-driven score used only to rank/refine coarse hypotheses (the real gate is `evaluate`).
    /// Rewards white evidence along the four edges plus a grass-dominant interior, with small bonuses
    /// for a center-circle ridge ring and a halfway line — structure unique to a real pitch.
    private func coarseScore(_ hypothesis: RectHypothesis, maps: RidgeMaps)
        -> (score: Double, grass: Double, supportedEdges: Int) {
        let center = hypothesis.center
        let u = CGPoint(x: cos(hypothesis.angle), y: sin(hypothesis.angle))
        let v = CGPoint(x: -sin(hypothesis.angle), y: cos(hypothesis.angle))

        // Interior grass FIRST, sampled on a dense grid reaching CLOSE to the box edges (inset 0.85):
        // a real pitch is grass corner-to-corner, so this collapses toward zero the moment a candidate
        // spills onto a parking lot, building or pond — the structures whose painted lines / rooflines
        // otherwise out-shine faint chalk and pull the search off the field. Cheap; runs before the
        // edge scan so off-field hypotheses bail immediately.
        var grassSum = 0.0
        var grassTaps = 0.0
        for su in stride(from: -0.72, through: 0.72, by: 0.36) {
            for sv in stride(from: -0.72, through: 0.72, by: 0.36) {
                let point = CGPoint(x: center.x + u.x * su * hypothesis.halfLength + v.x * sv * hypothesis.halfWidth,
                                    y: center.y + u.y * su * hypothesis.halfLength + v.y * sv * hypothesis.halfWidth)
                grassSum += Double(maps.grassAt(point))
                grassTaps += 1
            }
        }
        let grass = grassTaps > 0 ? grassSum / grassTaps : 0
        guard grass >= 0.40 else { return (0, grass, 0) }
        // Smooth grass gate: 0 below 0.40, full above 0.70. Multiplies the whole line-based score so a
        // candidate can never win on strong edges alone (parking-lot stripes / rooflines) — it must
        // ALSO be grass-dominant. Sampled at inset 0.72 (not right to the corners) so a real pitch whose
        // touchlines abut a building/road at the frame isn't unfairly starved.
        let grassFactor = min(1.0, max(0.0, (grass - 0.40) / 0.30))

        let corners = hypothesis.corners()

        // Edge white coverage. The perpendicular search spans ±`searchRadius` px — WIDE enough that a
        // candidate sitting ~10–20 px off the real touchline (well within a hill-climb step) still
        // FEELS the line — but each hit is weighted by a linear falloff so the score PEAKS when the
        // edge lies exactly on the line. That gives hill-climb a gradient that both pulls the box onto
        // the markings and then tightens it there (the earlier ±3 px window saw nothing until already
        // aligned, so grass — uniform across the field — dominated and the box drifted too wide).
        let searchRadius: CGFloat = 14
        var coverages = [Double](repeating: 0, count: 4)
        var supportedEdges = 0
        for edge in 0..<4 {
            let a = corners[edge]
            let b = corners[(edge + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(6, min(20, Int(length / 18)))
            var normal = CGPoint(x: -(b.y - a.y), y: b.x - a.x)
            let normalLength = hypot(normal.x, normal.y)
            if normalLength > 0 { normal = CGPoint(x: normal.x / normalLength, y: normal.y / normalLength) }
            var edgeSum = 0.0
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let base = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                var best = 0.0
                for offset in stride(from: -searchRadius, through: searchRadius, by: 2) {
                    let white = Double(maps.whiteAt(CGPoint(x: base.x + normal.x * offset, y: base.y + normal.y * offset)))
                    let falloff = 1 - 0.6 * Double(abs(offset)) / Double(searchRadius)
                    best = max(best, white * falloff)
                }
                edgeSum += best
            }
            let coverage = edgeSum / Double(steps + 1)
            coverages[edge] = coverage
            if coverage > 0.12 { supportedEdges += 1 }
        }
        // Score by the WEAKEST pair of edges, not the mean. A pitch is a COMPLETE rectangle, so even
        // its two faintest edges sit on lines; clutter (a parking-lot boundary, a tree line) gives one
        // or two strong edges but leaves the opposite edges empty, collapsing the weak-pair term to ~0.
        // Maximizing this pulls hill-climb onto the whole outline instead of onto the single strongest
        // line it can find — the behaviour that had every box drifting to the frame's clutter side.
        let sorted = coverages.sorted()
        let weakPair = (sorted[0] + sorted[1]) / 2
        let strongPair = (sorted[2] + sorted[3]) / 2
        let edgeCoverage = 0.70 * weakPair + 0.30 * strongPair

        // Pitch-specific bonuses (ranking only): center-circle ridge ring + halfway line.
        let circleRadius = min(hypothesis.halfLength, hypothesis.halfWidth) * 0.28
        var ringSum: Float = 0
        let ringTaps = 12
        for k in 0..<ringTaps {
            let phi = CGFloat(k) / CGFloat(ringTaps) * 2 * .pi
            let point = CGPoint(x: center.x + cos(phi) * circleRadius, y: center.y + sin(phi) * circleRadius)
            ringSum = max(ringSum, maps.whiteAt(point))
        }
        var halfwaySum = 0.0
        let halfwayTaps = 6
        for k in 0...halfwayTaps {
            let s = (CGFloat(k) / CGFloat(halfwayTaps) - 0.5) * 2
            let point = CGPoint(x: center.x + v.x * s * hypothesis.halfWidth, y: center.y + v.y * s * hypothesis.halfWidth)
            halfwaySum += Double(maps.whiteAt(point))
        }
        let halfway = halfwaySum / Double(halfwayTaps + 1)

        let aspect = hypothesis.halfLength / max(hypothesis.halfWidth, 1)
        let aspectDelta = Double(aspect) - 1.5
        let aspectPrior = exp(-(aspectDelta * aspectDelta) / (2 * 0.6 * 0.6))

        // Line evidence drives the framing, but the whole thing is GATED by grass (multiplicative): a
        // box on parking-lot stripes scores ~0 no matter how crisp those stripes are. A small additive
        // grass pull keeps the initial climb anchored on the field before any line is found.
        let lineScore = 0.72 * edgeCoverage + 0.10 * aspectPrior
            + 0.10 * Double(ringSum) + 0.05 * halfway
        let score = lineScore * grassFactor + 0.04 * grass
        return (score, grass, supportedEdges)
    }

    /// Coordinate-descent refinement: nudge center / size / angle to maximize the coarse score, so a
    /// hypothesis that merely overlaps the pitch snaps onto its actual outline before full scoring.
    private func hillClimb(_ start: RectHypothesis, maps: RidgeMaps, frame: CGFloat) -> RectHypothesis {
        var best = start
        best.score = coarseScore(best, maps: maps).score
        var positionStep = frame * 0.05
        var sizeStep = frame * 0.05
        var angleStep = CGFloat(7 * Double.pi / 180)
        for _ in 0..<9 {
            var improved = false
            let candidates: [RectHypothesis] = [
                mutate(best) { $0.center.x += positionStep }, mutate(best) { $0.center.x -= positionStep },
                mutate(best) { $0.center.y += positionStep }, mutate(best) { $0.center.y -= positionStep },
                mutate(best) { $0.halfLength += sizeStep }, mutate(best) { $0.halfLength = max(20, $0.halfLength - sizeStep) },
                mutate(best) { $0.halfWidth += sizeStep }, mutate(best) { $0.halfWidth = max(14, $0.halfWidth - sizeStep) },
                mutate(best) { $0.angle += angleStep }, mutate(best) { $0.angle -= angleStep }
            ]
            for var candidate in candidates {
                let aspect = candidate.halfLength / max(candidate.halfWidth, 1)
                guard aspect >= 1.15, aspect <= 2.2 else { continue }   // stay pitch-shaped, resist clutter drift
                candidate.score = coarseScore(candidate, maps: maps).score
                if candidate.score > best.score { best = candidate; improved = true }
            }
            if !improved { positionStep *= 0.55; sizeStep *= 0.55; angleStep *= 0.55 }
        }
        return best
    }

    private func mutate(_ hypothesis: RectHypothesis, _ body: (inout RectHypothesis) -> Void) -> RectHypothesis {
        var copy = hypothesis
        body(&copy)
        return copy
    }

    /// Two hypotheses are near-duplicates if their centers are close and their sizes similar — used to
    /// thin refined candidates before the (more expensive) full scorer runs.
    private func near(_ a: RectHypothesis, _ b: RectHypothesis, frame: CGFloat) -> Bool {
        hypot(a.center.x - b.center.x, a.center.y - b.center.y) < frame * 0.06
            && abs(a.halfLength - b.halfLength) < frame * 0.06
            && abs(a.halfWidth - b.halfWidth) < frame * 0.06
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
        var supportedEdges: Int
        var roughness: Double
        var passes: Bool
    }

    /// Score a candidate. `edgeImagePoints` are the fitted rectangle's four corners in image space
    /// (top-left origin), in ring order. Internal so the DEBUG harness can log the breakdown.
    func evaluate(edgeImagePoints: [CGPoint], sampler: PixelSampler, rectangle: OrientedRectangle) -> Evaluation {
        let line = perimeterLineSupport(corners: edgeImagePoints, sampler: sampler)
        let interior = interiorField(corners: edgeImagePoints, sampler: sampler)
        let grassFraction = interior.grass
        let aspectPrior = aspectPrior(for: rectangle)

        let score = Tuning.lineWeight * line.fraction
            + Tuning.grassWeight * grassFraction
            + Tuning.aspectWeight * aspectPrior

        // A pitch is boxed by touchlines on multiple sides. Requiring markings on ≥2 of the 4 edges
        // rejects a grass strip that merely borders a bright concrete curb/road on a single side
        // (one white-ish edge is not a pitch), while staying tolerant enough not to drop a real pitch
        // whose far touchlines are faint or partly shadowed.
        //
        let passes = grassFraction >= Tuning.minGrassFraction
            && line.fraction >= Tuning.minLineFraction
            && line.supportedEdges >= 2
            && score >= Tuning.minScore
        return Evaluation(score: score, lineFraction: line.fraction, grassFraction: grassFraction,
                          aspectPrior: aspectPrior, supportedEdges: line.supportedEdges,
                          roughness: interior.roughness, passes: passes)
    }

    /// Extra precision gate applied ONLY to model-driven (ridge-search) candidates, which — unlike a
    /// crisp Vision quad — are prone to latching onto high-texture clutter (a tree line, a car-filled
    /// parking lot, rooftops) that happens to read as green. Interior roughness (brightness std-dev)
    /// catches those; the ceiling is waived when the candidate already shows a strong, near-complete
    /// outline (≥3 supported edges), which is itself decisive pitch evidence and whose own crisp
    /// markings legitimately raise roughness. Not applied to Vision candidates, so it never costs the
    /// recall the existing crisp-complex path already delivers.
    private func passesRidgePrecisionGate(_ evaluation: Evaluation) -> Bool {
        let hasStrongOutline = evaluation.supportedEdges >= 3 && evaluation.lineFraction >= 0.17
        return evaluation.roughness <= Tuning.maxInteriorRoughness || hasStrongOutline
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

    /// Interior field evidence: the fraction of interior samples reading as field surface under a
    /// wide, hue-tolerant grass band (vivid green → yellow-green → worn brown, including shadowed
    /// turf), AND a `roughness` = std-dev of interior brightness. A real pitch — worn or lush — is a
    /// SMOOTH surface (low roughness); tree canopy, a parking lot full of cars, and rooftops are
    /// high-texture. Roughness is what finally separates a pitch from the vegetation / parking clutter
    /// that reads as "green" per-pixel and kept passing the colour-only grass test.
    private func interiorField(corners: [CGPoint], sampler: PixelSampler) -> (grass: Double, roughness: Double) {
        guard corners.count == 4 else { return (0, 1) }
        let center = centroid(of: corners)
        var grassTotal = 0.0
        var brightnessTotal = 0.0
        var brightnessSquaredTotal = 0.0
        var samples = 0.0
        // Sample a grid biased toward the interior (0.7 inset) so touchlines and adjacent surfaces
        // outside the pitch don't pollute the estimate.
        for u in stride(from: -0.7, through: 0.7, by: 0.2) {
            for v in stride(from: -0.7, through: 0.7, by: 0.2) {
                // Bilinear interior point from the centre toward each corner.
                let point = interiorPoint(corners: corners, center: center, u: u, v: v)
                guard let rgb = sampler.rgb(at: point) else { continue }
                grassTotal += fieldLikelihood(r: rgb.r, g: rgb.g, b: rgb.b)
                let brightness = (rgb.r + rgb.g + rgb.b) / 3
                brightnessTotal += brightness
                brightnessSquaredTotal += brightness * brightness
                samples += 1
            }
        }
        guard samples > 0 else { return (0, 1) }
        let mean = brightnessTotal / samples
        let variance = max(0, brightnessSquaredTotal / samples - mean * mean)
        return (grassTotal / samples, sqrt(variance))
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
        SatelliteFieldDetector.staticFieldLikelihood(r: r, g: g, b: b)
    }

    /// Static form so the ridge-map builder (which has no detector instance) shares the exact same
    /// grass model as the interior scorer.
    static func staticFieldLikelihood(r: Double, g: Double, b: Double) -> Double {
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
