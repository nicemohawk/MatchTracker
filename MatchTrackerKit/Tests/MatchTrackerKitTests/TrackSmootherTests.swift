import XCTest
@testable import MatchTrackerKit

final class TrackSmootherTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 0)

    private func point(lat: Double, lon: Double, offset: Double, accuracy: Double = 5) -> TrackPoint {
        TrackPoint(coordinate: Coordinate2D(latitude: lat, longitude: lon), timestamp: start.addingTimeInterval(offset),
                   speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: accuracy)
    }

    // MARK: - Strict no-op

    func testEmptyHeadingsIsStrictNoOp() {
        let track = (0..<6).map { point(lat: 40.0 + Double($0) * 1e-4, lon: -83.0, offset: Double($0)) }
        let fused = TrackSmoother.fuse(track: track, headings: [])

        XCTAssertEqual(fused.count, track.count)
        for (original, result) in zip(track, fused) {
            XCTAssertEqual(original.coordinate.latitude, result.coordinate.latitude)
            XCTAssertEqual(original.coordinate.longitude, result.coordinate.longitude)
            XCTAssertEqual(original.timestamp, result.timestamp)
        }
    }

    // MARK: - Gap interpolation

    func testInterpolatesAcrossGap() {
        let a = point(lat: 40.0, lon: -83.0, offset: 0)
        let b = point(lat: 40.0, lon: -83.0 + 1e-3, offset: 10)   // ~85 m east, 10 s later
        let headings = [HeadingSample(timestamp: start, headingDegrees: 90),
                        HeadingSample(timestamp: start.addingTimeInterval(10), headingDegrees: 90)]

        let fused = TrackSmoother.fuse(track: [a, b], headings: headings)

        XCTAssertGreaterThan(fused.count, 2, "a 10 s gap must be filled")
        XCTAssertEqual(fused.count, 11, "two anchors + nine 1 Hz interior fills")
        // Output stays sorted and preserves the anchors.
        for index in 1..<fused.count {
            XCTAssertLessThan(fused[index - 1].timestamp, fused[index].timestamp)
        }
        XCTAssertEqual(fused.first?.timestamp, a.timestamp)
        XCTAssertEqual(fused.last?.timestamp, b.timestamp)
        XCTAssertGreaterThanOrEqual(fused.count, [a, b].count, "count never drops below the input")
    }

    func testShortGapNotInterpolated() {
        // A 2 s step is at the threshold and must not be filled.
        let a = point(lat: 40.0, lon: -83.0, offset: 0)
        let b = point(lat: 40.0, lon: -83.0 + 1e-4, offset: 2)
        let headings = [HeadingSample(timestamp: start, headingDegrees: 90)]

        let fused = TrackSmoother.fuse(track: [a, b], headings: headings)
        XCTAssertEqual(fused.count, 2)
    }

    // MARK: - Jitter reduction

    func testAccuracyWeightedSmoothingReducesJitter() {
        // Straight eastward path (1 Hz, no gaps) with alternating north jitter.
        let baseLat = 40.0
        let jitter = 3e-5   // ~3 m
        var track: [TrackPoint] = []
        for i in 0..<20 {
            let lat = baseLat + (i % 2 == 0 ? jitter : -jitter)
            track.append(point(lat: lat, lon: -83.0 + Double(i) * 1e-4, offset: Double(i)))
        }
        let headings = [HeadingSample(timestamp: start, headingDegrees: 90)]

        let fused = TrackSmoother.fuse(track: track, headings: headings)
        XCTAssertEqual(fused.count, track.count, "no gaps -> no new points, just smoothing")

        func variance(_ points: [TrackPoint]) -> Double {
            let deviations = points[1..<(points.count - 1)].map { $0.coordinate.latitude - baseLat }
            let mean = deviations.reduce(0, +) / Double(deviations.count)
            return deviations.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(deviations.count)
        }

        XCTAssertLessThan(variance(fused), variance(track) * 0.5, "3-point averaging cuts interior jitter")
    }
}
