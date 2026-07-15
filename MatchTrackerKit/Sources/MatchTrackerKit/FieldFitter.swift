import Foundation
import CoreGraphics

// MARK: - Robust field fitting
//
// The problem this file exists to fix: a match GPS track is NOT just the pitch. It also contains
// the walk from the car, a warm-up lap AROUND the touchline, a halftime cluster on the bench, and
// stray outliers. Bounding-box style fitting (hull + min-area rectangle over trimmed radial
// outliers) happily swallows all of that, drawing a field bigger than the pitch and leaving
// genuinely off-field route data flagged as "on field".
//
// `FieldFitter` instead fits the DENSE CORE of play and rejects the rest:
//   1. Orientation comes from PCA over *occupied grid cells* (each cell counted once), so a long
//      stationary stand (car, bench) or a thin one-pass warm-up lap can't drag the axis — they
//      occupy few cells, or low-density cells, relative to the 2-D mass of real play.
//   2. Extents come from a per-axis density scan in that oriented frame: a contiguous run of
//      high-density bins around the core. Sparse tails (parking walk), low-density fringes (warm-up
//      lap just outside the touchline), and gapped-off clusters (bench) all fall away.

public enum FieldFitter {
    /// Grid cell size (m) for the density raster used by orientation and to seed the fit.
    private static let cellSizeMeters = 3.0
    /// Histogram bin size (m) for the per-axis extent scan.
    private static let binSizeMeters = 3.0
    /// A bin (or expansion step) may bridge at most this many consecutive sub-threshold bins.
    /// One 3 m bin bridges brief sparseness inside play but not an 8 m bench gap.
    private static let gapToleranceBins = 1
    /// Keep extent bins whose count is at least this fraction of the core (play) density. Set so a
    /// warm-up lap's concentrated just-outside-the-touchline edge run stays below the cut while
    /// genuine play near the touchline stays above it.
    private static let extentDensityFraction = 0.5
    /// Cells this dense (fraction of the peak cell) count toward the orientation fit; on a dense
    /// track this drops thin one-pass appendages, while a floor of 2 always sheds singleton outliers.
    private static let orientationDensityFraction = 0.15
    /// Below this many dense cells the strict cut is too sparse to trust; loosen to shed only singletons.
    private static let minOrientationCells = 24
    /// Players don't quite reach the touchlines; nudge the fitted core out by this factor.
    private static let touchlineExpansion = 1.04
    /// Plausible pitch aspect (long / short) the fit is clamped into.
    private static let minAspect = 1.2
    private static let maxAspect = 2.2
    /// Plausible per-side dimensions (m) the fit is clamped into.
    private static let minSideMeters = 25.0
    private static let maxSideMeters = 130.0
    /// A core narrower than this (m) isn't a 2-D field (a line, a road, a single pass).
    private static let minCoreWidthMeters = 5.0

    /// Robust field fit from a match track: fits the DENSE CORE of play, rejecting warm-up walks,
    /// sideline stints, and outliers — NOT a bounding box. Deterministic; runs in well under 50 ms
    /// for 10 000 points. Returns nil when no field-shaped core of play can be found.
    public static func fitFieldRectangle(track: [TrackPoint]) -> OrientedRectangle? {
        let accurate = track.filter {
            $0.horizontalAccuracy <= TrackPoint.maximumUsableHorizontalAccuracy && isPlausibleCoordinate($0.coordinate)
        }
        guard accurate.count >= 8 else { return nil }

        let coordinates = accurate.map(\.coordinate)
        let frame = ENUFrame(reference: centroid(of: coordinates))
        let projected = coordinates.map { frame.project($0) }

        guard let headingDegrees = orientation(of: projected) else { return nil }

        // Rotate every point into the oriented (long = u, short = v) frame. The rotation matrix is
        // its own inverse, so the same expression un-rotates the fitted center below.
        let radians = headingDegrees * .pi / 180
        let sinValue = sin(radians)
        let cosValue = cos(radians)
        let longCoords = projected.map { Double($0.x) * sinValue + Double($0.y) * cosValue }
        let shortCoords = projected.map { Double($0.x) * cosValue - Double($0.y) * sinValue }

        guard let longExtent = coreExtent(longCoords),
              let shortExtent = coreExtent(shortCoords) else { return nil }

        var length = longExtent.upper - longExtent.lower
        var width = shortExtent.upper - shortExtent.lower
        let centerU = (longExtent.lower + longExtent.upper) / 2
        let centerV = (shortExtent.lower + shortExtent.upper) / 2

        // Reject a degenerate (essentially 1-D) core: a road, a straight sprint, a single lap edge.
        guard min(length, width) >= minCoreWidthMeters else { return nil }

        // Nudge out to the touchline the players never quite reached.
        length *= touchlineExpansion
        width *= touchlineExpansion

        var lengthMeters = max(length, width)
        var widthMeters = min(length, width)
        // If the short axis came out longer, the "long" axis was actually the short one: rotate 90°.
        var heading = headingDegrees
        if width > length { heading = foldHeading(headingDegrees + 90) }

        // Clamp into a plausible pitch envelope.
        lengthMeters = min(max(lengthMeters, minSideMeters), maxSideMeters)
        widthMeters = min(max(widthMeters, minSideMeters), maxSideMeters)
        let aspect = lengthMeters / widthMeters
        if aspect > maxAspect {
            widthMeters = lengthMeters / maxAspect
        } else if aspect < minAspect {
            widthMeters = lengthMeters / minAspect
        }

        // Un-rotate the (u, v) center back into ENU, then into world coordinates.
        let centerEast = centerU * sinValue + centerV * cosValue
        let centerNorth = centerU * cosValue - centerV * sinValue
        let center = frame.unproject(CGPoint(x: centerEast, y: centerNorth))

        return makeOrientedRectangle(
            center: center,
            lengthMeters: lengthMeters,
            widthMeters: widthMeters,
            headingDegrees: heading
        )
    }

    // MARK: - Orientation

    /// Long-axis compass heading (0..<180) from the minimum-area rectangle of *occupied grid cells*.
    /// Counting each cell once — rather than each point — strips the density bias of a stationary
    /// stand: a bench or parked-car cluster becomes a single cell, so it cannot rotate the axis (and
    /// even the dimensions it might inflate are discarded — only the heading is taken here; extents
    /// come from the density scan). Thin one-pass appendages (a warm-up lap, a walk-in tail) are
    /// low-density cells dropped by the count threshold. Min-area rectangle stays stable on the
    /// sparse, clumpy cell clouds where a covariance axis would wobble.
    private static func orientation(of projected: [CGPoint]) -> Double? {
        var counts: [GridKey: Int] = [:]
        for point in projected {
            counts[GridKey(point, cellSizeMeters), default: 0] += 1
        }
        guard let peak = counts.values.max() else { return nil }
        let threshold = max(2, Int((Double(peak) * orientationDensityFraction).rounded()))

        // Dense cell centers (ENU meters). Fall back to a looser (singletons-only) cut if the strict
        // cut is too thin to fit stably, and finally to the raw cloud for very sparse tracks.
        var centers = cellCenters(counts, threshold: threshold)
        if centers.count < minOrientationCells { centers = cellCenters(counts, threshold: 2) }
        if centers.count < 3 { centers = projected }
        guard centers.count >= 3 else { return nil }

        return minimumAreaRectangle(for: centers)?.headingDegrees
    }

    private static func cellCenters(_ counts: [GridKey: Int], threshold: Int) -> [CGPoint] {
        counts.compactMap { key, count in
            count >= threshold
                ? CGPoint(x: (Double(key.column) + 0.5) * cellSizeMeters,
                          y: (Double(key.row) + 0.5) * cellSizeMeters)
                : nil
        }
    }

    // MARK: - Per-axis extent

    private struct Extent { var lower: Double; var upper: Double }

    /// Robust extent of the play core along one axis. A 1-D density histogram is scanned outward
    /// from the median-value bin: first following contiguity (so a gapped-off bench cluster is left
    /// behind), then following density (so a sparse parking tail and the low-density warm-up-lap
    /// fringe are trimmed). The result is the outer edges of the dense contiguous core.
    private static func coreExtent(_ values: [Double]) -> Extent? {
        guard values.count >= 8 else { return nil }
        let lower = values.min()!
        let upper = values.max()!
        let span = upper - lower
        guard span > 1e-6 else { return nil }

        let binCount = max(1, Int((span / binSizeMeters).rounded(.up)))
        var bins = [Int](repeating: 0, count: binCount)
        func index(of value: Double) -> Int {
            min(binCount - 1, max(0, Int((value - lower) / binSizeMeters)))
        }
        for value in values { bins[index(of: value)] += 1 }

        // Seed inside the dense mass: the bin holding the median value (robust to off-field tails).
        let seed = index(of: median(values))

        // Stage 1 — contiguity: the reachable region around the seed, bridging tiny (<= gap) holes.
        // This walls off a bench cluster sitting across an empty gap while keeping a contiguous tail.
        let region = reachableRegion(bins, seed: seed, floor: 1)

        // Stage 2 — density: reference = median of the substantial bins within the reachable region
        // (ignoring its sparse tail). Keep the contiguous run around the seed at/above the fraction.
        let regionBins = Array(bins[region.lower...region.upper])
        let peak = regionBins.max() ?? 0
        let substantial = regionBins.filter { $0 >= Int((0.25 * Double(peak)).rounded()) }.sorted()
        guard let reference = substantial.isEmpty ? regionBins.sorted().last : substantial[substantial.count / 2],
              reference > 0 else { return nil }
        let threshold = max(1, Int((extentDensityFraction * Double(reference)).rounded()))

        let core = expand(bins, seed: seed, bounds: region, floor: threshold)

        // Tighten to the actual extreme values inside the kept bins (removes up-to-one-bin rounding
        // slop, so a fill that reaches the touchline fits the touchline, not a bin edge past it).
        var coreLower = Double.greatestFiniteMagnitude
        var coreUpper = -Double.greatestFiniteMagnitude
        for value in values where (core.lower...core.upper).contains(index(of: value)) {
            coreLower = min(coreLower, value)
            coreUpper = max(coreUpper, value)
        }
        guard coreLower <= coreUpper else { return nil }
        return Extent(lower: coreLower, upper: coreUpper)
    }

    /// Contiguous bin range around `seed` where every included bin has count >= `floor`, allowing at
    /// most `gapToleranceBins` consecutive sub-floor bins to be bridged.
    private static func reachableRegion(_ bins: [Int], seed: Int, floor: Int) -> (lower: Int, upper: Int) {
        expand(bins, seed: seed, bounds: (0, bins.count - 1), floor: floor)
    }

    /// Expand outward from `seed` inside `bounds`, including bins with count >= `floor` and bridging
    /// up to `gapToleranceBins` consecutive sub-floor bins before stopping.
    private static func expand(_ bins: [Int], seed: Int, bounds: (lower: Int, upper: Int), floor: Int) -> (lower: Int, upper: Int) {
        var low = min(max(seed, bounds.lower), bounds.upper)
        var high = low

        var gap = 0
        var i = low
        while i - 1 >= bounds.lower {
            if bins[i - 1] >= floor { low = i - 1; gap = 0 }
            else if gap < gapToleranceBins { gap += 1 }
            else { break }
            i -= 1
        }

        gap = 0
        i = high
        while i + 1 <= bounds.upper {
            if bins[i + 1] >= floor { high = i + 1; gap = 0 }
            else if gap < gapToleranceBins { gap += 1 }
            else { break }
            i += 1
        }
        return (low, high)
    }
}

/// Integer grid cell key over an ENU meters plane, snapped at a fixed cell size.
private struct GridKey: Hashable {
    let column: Int
    let row: Int
    init(_ point: CGPoint, _ cellSize: Double) {
        column = Int((Double(point.x) / cellSize).rounded(.down))
        row = Int((Double(point.y) / cellSize).rounded(.down))
    }
}

// MARK: - Offline playing-interval derivation

public enum PlayIntervalDeriver {
    /// Replay the geometry sub-detection rule over a finished track, so that correcting a field
    /// recomputes time-on-pitch offline. Semantics mirror the live `AutoSubDetector` geometry rule:
    /// staying continuously beyond touchline + `marginMeters` for over 30 s opens a bench spell;
    /// stepping back inside (held briefly to debounce GPS blips) closes it. Returns the on-pitch
    /// intervals between `matchStart` and `matchEnd`. With no bench spell the whole match is one
    /// interval.
    public static func playingIntervals(track: [TrackPoint],
                                        field: OrientedRectangle,
                                        matchStart: Date,
                                        matchEnd: Date,
                                        marginMeters: Double) -> [DateInterval] {
        guard matchEnd > matchStart else { return [] }

        var configuration = AutoSubDetectorConfiguration()
        configuration.exitDistanceMeters = marginMeters   // "outside touchline + margin" == off pitch

        let projector = FieldProjector(rectangle: field)
        let events = AutoSubDetector.detectEvents(
            track: track,
            projector: projector,
            existingEvents: [],
            configuration: configuration
        )
        return SubstitutionTracker.playingIntervals(events: events, matchStart: matchStart, matchEnd: matchEnd)
    }
}
