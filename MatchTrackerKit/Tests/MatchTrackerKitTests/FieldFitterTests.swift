import XCTest
import CoreGraphics
@testable import MatchTrackerKit

/// Tests for the robust dense-core field fit, the on-field gate, and offline playing-interval
/// derivation. Synthetic tracks carry ground truth so each hazard (warm-up lap, parking-walk tail,
/// bench cluster) can be asserted against the true pitch rather than the raw route bounding box.
final class FieldFitterTests: XCTestCase {

    // MARK: - Test support

    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var x = state
            x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
            return x
        }
    }

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)

    private func rectangle(center: Coordinate2D, length: Double, width: Double, heading: Double) -> OrientedRectangle {
        makeOrientedRectangle(center: center, lengthMeters: length, widthMeters: width, headingDegrees: heading)
    }

    /// Place a normalized field point (x along long axis, y along short) into world coords. Values
    /// outside [0,1] extrapolate beyond the touchline (used to place laps and bench clusters).
    private func place(_ rect: OrientedRectangle, x: Double, y: Double) -> Coordinate2D {
        let frame = ENUFrame(reference: rect.center)
        let radians = rect.headingDegrees * .pi / 180
        let longAxis = CGPoint(x: sin(radians), y: cos(radians))
        let shortAxis = CGPoint(x: cos(radians), y: -sin(radians))
        let along = (x - 0.5) * rect.lengthMeters
        let across = (y - 0.5) * rect.widthMeters
        let east = along * Double(longAxis.x) + across * Double(shortAxis.x)
        let north = along * Double(longAxis.y) + across * Double(shortAxis.y)
        return frame.unproject(CGPoint(x: east, y: north))
    }

    private func headingDelta(_ a: Double, _ b: Double) -> Double {
        let raw = abs(foldHeading(a) - foldHeading(b))
        return min(raw, 180 - raw)
    }

    private func point(_ coordinate: Coordinate2D, _ time: Double, accuracy: Double = 5) -> TrackPoint {
        TrackPoint(coordinate: coordinate, timestamp: Date(timeIntervalSince1970: time),
                   speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: accuracy)
    }

    /// A uniform fill of the pitch (players cover the whole field), 1 sample/sec from `start`.
    private func playFill(_ rect: OrientedRectangle, count: Int, seed: UInt64, start: Double = 0) -> [TrackPoint] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            point(place(rect, x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng)),
                  start + Double(index))
        }
    }

    /// Assert a fitted rectangle matches a true pitch to within `edgeTolerance` metres on each side.
    private func assertMatches(_ fitted: OrientedRectangle, true trueRect: OrientedRectangle,
                               edgeTolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fitted.lengthMeters, trueRect.lengthMeters, accuracy: 2 * edgeTolerance,
                       "length", file: file, line: line)
        XCTAssertEqual(fitted.widthMeters, trueRect.widthMeters, accuracy: 2 * edgeTolerance,
                       "width", file: file, line: line)
        XCTAssertLessThan(headingDelta(fitted.headingDegrees, trueRect.headingDegrees), 5,
                          "heading", file: file, line: line)
        XCTAssertLessThan(haversineMeters(fitted.center, trueRect.center), edgeTolerance,
                          "center", file: file, line: line)
    }

    // MARK: - (a) Clean play

    func testFitPlayOnlyMatchesTrueRectangle() {
        let truth = rectangle(center: fieldCenter, length: 100, width: 64, heading: 20)
        let track = playFill(truth, count: 2400, seed: 11)
        let fitted = try! XCTUnwrap(FieldFitter.fitFieldRectangle(track: track))
        assertMatches(fitted, true: truth, edgeTolerance: 3)
    }

    // MARK: - (b) Perimeter warm-up lap

    func testFitIgnoresPerimeterWarmupLap() {
        let truth = rectangle(center: fieldCenter, length: 100, width: 64, heading: 20)
        var track = playFill(truth, count: 2400, seed: 12)

        // One slow lap ~3 m outside every touchline (a single low-density pass around the pitch).
        let offsetX = 3.0 / truth.lengthMeters
        let offsetY = 3.0 / truth.widthMeters
        var time = 3000.0
        func lapPoint(_ x: Double, _ y: Double) {
            track.append(point(place(truth, x: x, y: y), time)); time += 1
        }
        for step in stride(from: 0.0, through: 1.0, by: 0.02) {
            lapPoint(step, -offsetY)
            lapPoint(step, 1 + offsetY)
        }
        for step in stride(from: 0.0, through: 1.0, by: 0.03) {
            lapPoint(-offsetX, step)
            lapPoint(1 + offsetX, step)
        }

        let fitted = try! XCTUnwrap(FieldFitter.fitFieldRectangle(track: track))
        // The lap would push each edge ~3 m out (length ~106, width ~70); the fit must stay near truth.
        assertMatches(fitted, true: truth, edgeTolerance: 4)
        XCTAssertLessThan(fitted.lengthMeters, 108, "lap extent must not define the length")
        XCTAssertLessThan(fitted.widthMeters, 72, "lap extent must not define the width")
    }

    // MARK: - (c) Parking-walk tail

    func testFitRejectsParkingWalkTail() {
        let truth = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        var track = playFill(truth, count: 2400, seed: 13)

        // A 200 m sparse walk in from the car, off one end of the pitch (1 sample/metre).
        var time = 3000.0
        for step in stride(from: 0.0, through: 200.0, by: 1.0) {
            let x = 1.0 + (200.0 - step) / truth.lengthMeters   // starts ~200 m past the end, walks in
            track.append(point(place(truth, x: x, y: 0.5), time))
            time += 1
        }

        let fitted = try! XCTUnwrap(FieldFitter.fitFieldRectangle(track: track))
        assertMatches(fitted, true: truth, edgeTolerance: 5)
        XCTAssertLessThan(fitted.lengthMeters, 120, "the 200 m tail must not stretch the field")
    }

    // MARK: - (d) Halftime bench cluster

    func testFitExcludesBenchClusterAndDerivesBenchInterval() {
        let truth = rectangle(center: fieldCenter, length: 100, width: 64, heading: 0)

        var track = playFill(truth, count: 600, seed: 14, start: 0)          // first half
        // Halftime: sit ~8 m outside the sideline for 90 s.
        var rng = SeededGenerator(seed: 140)
        let benchY = 1.0 + 8.0 / truth.widthMeters
        for index in 0..<90 {
            let jitterX = 0.5 + Double.random(in: -0.01...0.01, using: &rng)
            track.append(point(place(truth, x: jitterX, y: benchY), 600 + Double(index)))
        }
        track += playFill(truth, count: 600, seed: 15, start: 690)           // second half

        // Fit ignores the bench cluster: width stays near truth, not +16 m.
        let fitted = try! XCTUnwrap(FieldFitter.fitFieldRectangle(track: track))
        assertMatches(fitted, true: truth, edgeTolerance: 5)
        XCTAssertLessThan(fitted.widthMeters, 74, "bench cluster must not widen the field")

        // The bench spell shows up as a gap between two playing intervals.
        let intervals = PlayIntervalDeriver.playingIntervals(
            track: track, field: truth,
            matchStart: Date(timeIntervalSince1970: 0),
            matchEnd: Date(timeIntervalSince1970: 1290),
            marginMeters: 5)
        XCTAssertEqual(intervals.count, 2, "one bench spell splits the match into two playing intervals")
        XCTAssertEqual(intervals[0].end.timeIntervalSince1970, 600, accuracy: 10)
        XCTAssertEqual(intervals[1].start.timeIntervalSince1970, 690, accuracy: 10)
    }

    // MARK: - (e) On-field gate

    func testIsOnFieldMarginBehavior() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 30)
        let projector = FieldProjector(rectangle: rect)

        XCTAssertTrue(projector.isOnField(rect.center, marginMeters: 0))

        let threeOut = place(rect, x: 1.0 + 3.0 / rect.lengthMeters, y: 0.5)
        XCTAssertTrue(projector.isOnField(threeOut, marginMeters: 5), "3 m out is on-field at a 5 m margin")
        XCTAssertFalse(projector.isOnField(threeOut, marginMeters: 2), "3 m out is off-field at a 2 m margin")

        let farOut = place(rect, x: 1.0 + 30.0 / rect.lengthMeters, y: 0.5)
        XCTAssertFalse(projector.isOnField(farOut, marginMeters: 10), "30 m out is off-field at any sane margin")
    }

    // MARK: - (f) Playing intervals

    func testPlayingIntervalsWholeMatchOnField() {
        let truth = rectangle(center: fieldCenter, length: 100, width: 64, heading: 0)
        let track = playFill(truth, count: 1200, seed: 16)
        let intervals = PlayIntervalDeriver.playingIntervals(
            track: track, field: truth,
            matchStart: Date(timeIntervalSince1970: 0),
            matchEnd: Date(timeIntervalSince1970: 1199),
            marginMeters: 5)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start.timeIntervalSince1970, 0)
        XCTAssertEqual(intervals[0].end.timeIntervalSince1970, 1199)
    }

    func testPlayingIntervalsTwoBenchSpellsGiveThreeIntervals() {
        let truth = rectangle(center: fieldCenter, length: 100, width: 64, heading: 0)
        let benchY = 1.0 + 10.0 / truth.widthMeters

        var track: [TrackPoint] = []
        func play(_ from: Int, _ to: Int, seed: UInt64) {
            var rng = SeededGenerator(seed: seed)
            for time in from..<to {
                track.append(point(place(truth, x: Double.random(in: 0.1...0.9, using: &rng),
                                         y: Double.random(in: 0.1...0.9, using: &rng)), Double(time)))
            }
        }
        func bench(_ from: Int, _ to: Int) {
            for time in from..<to { track.append(point(place(truth, x: 0.5, y: benchY), Double(time))) }
        }

        play(0, 300, seed: 21)
        bench(300, 360)          // spell 1: 60 s off
        play(360, 700, seed: 22)
        bench(700, 800)          // spell 2: 100 s off
        play(800, 1200, seed: 23)

        let intervals = PlayIntervalDeriver.playingIntervals(
            track: track, field: truth,
            matchStart: Date(timeIntervalSince1970: 0),
            matchEnd: Date(timeIntervalSince1970: 1199),
            marginMeters: 5)
        XCTAssertEqual(intervals.count, 3, "two bench spells split the match into three playing intervals")
        XCTAssertEqual(intervals[0].end.timeIntervalSince1970, 300, accuracy: 10)
        XCTAssertEqual(intervals[1].start.timeIntervalSince1970, 360, accuracy: 10)
        XCTAssertEqual(intervals[1].end.timeIntervalSince1970, 700, accuracy: 10)
        XCTAssertEqual(intervals[2].start.timeIntervalSince1970, 800, accuracy: 10)
        XCTAssertEqual(intervals[2].end.timeIntervalSince1970, 1199)
    }

    // MARK: - Degenerate input

    func testFitRejectsNonFieldShapes() {
        // A straight line has no width.
        let frame = ENUFrame(reference: fieldCenter)
        let line = (0..<40).map { point(frame.unproject(CGPoint(x: Double($0) * 3, y: 0)), Double($0)) }
        XCTAssertNil(FieldFitter.fitFieldRectangle(track: line))

        // Too few points to trust.
        XCTAssertNil(FieldFitter.fitFieldRectangle(track: Array(line.prefix(4))))
    }
}
