import XCTest
import CoreGraphics
@testable import MatchTrackerKit

/// Ground-truth soccer-load metrics tests. Tracks are synthesized from explicit speed profiles by
/// integrating position east along a local ENU frame, so haversine step distance equals speed × dt
/// and every assertion has a known analytic target.
final class SoccerLoadMetricsTests: XCTestCase {

    private let origin = Coordinate2D(latitude: 40.0, longitude: -83.0)
    private let start = Date(timeIntervalSince1970: 0)

    /// Builds a track by walking east at a piecewise-constant speed. `segments` is a list of
    /// (speed m/s, duration s); points are emitted every `dt` seconds. `reportSpeed` controls
    /// whether each point carries its speed (true) or -1 so the engine derives it from geometry.
    private func track(segments: [(speed: Double, duration: Double)], dt: Double = 0.5,
                       reportSpeed: Bool = true) -> [TrackPoint] {
        let frame = ENUFrame(reference: origin)
        var points: [TrackPoint] = []
        var east = 0.0
        var time = 0.0
        // Seed the first point at rest position with the first segment's speed.
        func emit(speed: Double) {
            let coordinate = frame.unproject(CGPoint(x: east, y: 0))
            points.append(TrackPoint(coordinate: coordinate,
                                     timestamp: start.addingTimeInterval(time),
                                     speedMetersPerSecond: reportSpeed ? speed : -1,
                                     courseDegrees: -1, horizontalAccuracy: 5))
        }
        emit(speed: segments.first?.speed ?? 0)
        for segment in segments {
            let steps = Int((segment.duration / dt).rounded())
            for _ in 0..<steps {
                east += segment.speed * dt
                time += dt
                emit(speed: segment.speed)
            }
        }
        return points
    }

    // MARK: - 1. Band accumulation

    func testConstantSpeedSegmentsAccumulateBandDistances() {
        // 10 s below HSR (3 m/s), 10 s in HSR (6 m/s), 10 s sprinting (8 m/s), sampled at 1 Hz so
        // no smoothing blurs the constant segments. Expected: HSR ≈ 60 m, sprint ≈ 80 m.
        let points = track(segments: [(3, 10), (6, 10), (8, 10)], dt: 1.0)
        let metrics = SoccerLoadMetrics.compute(track: points, playingIntervals: [])

        XCTAssertEqual(metrics.highSpeedRunningMeters, 60, accuracy: 8,
                       "10 s at 6 m/s lands in the 5.5–7.0 band")
        XCTAssertEqual(metrics.sprintDistanceMeters, 80, accuracy: 8,
                       "10 s at 8 m/s is above the 7.0 sprint threshold")
        XCTAssertEqual(metrics.topSpeedMetersPerSecond, 8, accuracy: 0.5)
    }

    // MARK: - 2. One burst = one accel + one decel

    func testSingleSprintBurstProducesOneAccelerationAndOneDeceleration() {
        // Rest, accelerate 0→9 (+6 m/s²), hold at top speed, decelerate 9→0 (−6 m/s²), rest.
        let metrics = SoccerLoadMetrics.compute(track: rampTrack(), playingIntervals: [])

        XCTAssertEqual(metrics.accelerationCount, 1, "one contiguous acceleration up to top speed")
        XCTAssertEqual(metrics.decelerationCount, 1, "one contiguous deceleration back to rest")
        XCTAssertGreaterThan(metrics.sprintDistanceMeters, 0, "the burst crosses the sprint band")
        XCTAssertEqual(metrics.topSpeedMetersPerSecond, 9, accuracy: 1.0)
    }

    /// A rest → ramp-up → hold → ramp-down → rest track with linear ramps (so acceleration is a
    /// clean plateau at ±6 m/s²), used by the burst and debounce tests.
    private func rampTrack() -> [TrackPoint] {
        var profile: [(Double, Double)] = []
        profile.append((0, 2))                      // rest
        profile.append(contentsOf: linearRamp(from: 0, to: 9, over: 1.5)) // accelerate +6 m/s²
        profile.append((9, 3))                      // hold at top speed
        profile.append(contentsOf: linearRamp(from: 9, to: 0, over: 1.5)) // decelerate −6 m/s²
        profile.append((0, 2))                      // rest
        return track(segments: profile, dt: 0.5)
    }

    /// Splits a linear speed ramp into 0.5 s constant-speed sub-segments approximating a straight
    /// velocity line, so the derived acceleration is a steady plateau rather than one instant jump.
    private func linearRamp(from: Double, to: Double, over duration: Double,
                            dt: Double = 0.5) -> [(Double, Double)] {
        let steps = Int((duration / dt).rounded())
        guard steps > 0 else { return [(to, duration)] }
        var segments: [(Double, Double)] = []
        for step in 1...steps {
            let speed = from + (to - from) * Double(step) / Double(steps)
            segments.append((speed, dt))
        }
        return segments
    }

    // MARK: - 3. Debounce collapses closely-spaced efforts

    func testRepeatedBurstsRespectDebounce() {
        // Accel A, then accel B only ~1 s later (inside the 2 s debounce → collapses into A), then a
        // decel reset, then accel C well separated (counted). Net: 2 accelerations, 1 deceleration —
        // the closely-spaced A/B pair counts once, not twice.
        var profile: [(Double, Double)] = []
        profile.append((0, 1))                              // rest
        profile.append(contentsOf: linearRamp(from: 0, to: 6, over: 1))   // A
        profile.append((6, 1))                              // micro-plateau (< 2 s)
        profile.append(contentsOf: linearRamp(from: 6, to: 12, over: 1))  // B: debounced into A
        profile.append((12, 3))                             // long hold (> 2 s since A)
        profile.append(contentsOf: linearRamp(from: 12, to: 6, over: 1))  // decel reset
        profile.append((6, 1))                              // plateau
        profile.append(contentsOf: linearRamp(from: 6, to: 12, over: 1))  // C: counted
        profile.append((12, 1))
        let points = track(segments: profile, dt: 0.5)
        let metrics = SoccerLoadMetrics.compute(track: points, playingIntervals: [])

        XCTAssertEqual(metrics.accelerationCount, 2,
                       "the A/B pair collapses to one; C is the second counted acceleration")
        XCTAssertEqual(metrics.decelerationCount, 1, "the single 12→6 reset is one deceleration")
    }

    // MARK: - 4. Bench intervals excluded

    func testBenchTimeExcludedFromDistanceAndPerMinute() {
        // 6 m/s (HSR) for the whole 100 s, but only the first 50 s is on-pitch.
        let points = track(segments: [(6, 100)], dt: 1.0)
        let playing = [DateInterval(start: start, end: start.addingTimeInterval(50))]
        let metrics = SoccerLoadMetrics.compute(track: points, playingIntervals: playing)

        XCTAssertEqual(metrics.highSpeedRunningMeters, 300, accuracy: 12,
                       "only the on-pitch 50 s (≈300 m) counts, not the full 600 m")
        // 300 m over 50 s on pitch = 360 m/min.
        XCTAssertEqual(metrics.distancePerMinuteMeters, 360, accuracy: 20)
    }

    func testNoOnPitchTimeYieldsZeroDistancePerMinute() {
        let points = track(segments: [(6, 20)], dt: 1.0)
        // A playing interval entirely outside the track's time span → no on-pitch steps.
        let offPitch = [DateInterval(start: start.addingTimeInterval(1000),
                                     end: start.addingTimeInterval(1050))]
        let metrics = SoccerLoadMetrics.compute(track: points, playingIntervals: offPitch)
        XCTAssertEqual(metrics.distancePerMinuteMeters, 0)
        XCTAssertEqual(metrics.highSpeedRunningMeters, 0)
    }

    // MARK: - 5. Noise-only track produces ~zero load

    func testNoiseOnlyTrackProducesNoSprintOrEfforts() {
        // Jitter within ±0.3 m around a point at 0.5 s spacing, speed derived from geometry, plus a
        // couple of isolated single-sample GPS glitches. Smoothing must keep these from becoming
        // sprint distance or phantom accelerations.
        let frame = ENUFrame(reference: origin)
        var points: [TrackPoint] = []
        for index in 0..<80 {
            var east = (index % 2 == 0) ? 0.3 : -0.3   // small oscillation around the point
            if index == 20 || index == 55 { east += 2.0 } // single-sample jumps (would spike raw accel)
            let coordinate = frame.unproject(CGPoint(x: east, y: 0))
            points.append(TrackPoint(coordinate: coordinate,
                                     timestamp: start.addingTimeInterval(Double(index) * 0.5),
                                     speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: 8))
        }
        let metrics = SoccerLoadMetrics.compute(track: points, playingIntervals: [])

        XCTAssertEqual(metrics.sprintDistanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.highSpeedRunningMeters, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.accelerationCount, 0, "1 s smoothing damps the single-sample jumps")
        XCTAssertEqual(metrics.decelerationCount, 0)
    }

    // MARK: - 6. Outliers capped

    func testTopSpeedRejectsGlitchOutliers() {
        // Real motion at a constant 8 m/s, with one point reporting an impossible 25 m/s and one
        // teleport coordinate jump. Neither may set top speed or inflate sprint distance.
        var points = track(segments: [(8, 12)], dt: 0.5)
        // Corrupt one reported speed with an impossible value.
        points[6] = TrackPoint(coordinate: points[6].coordinate, timestamp: points[6].timestamp,
                               speedMetersPerSecond: 25, courseDegrees: -1, horizontalAccuracy: 5)
        // Teleport one coordinate 100 m sideways (a GPS jump), leaving its neighbours intact.
        let frame = ENUFrame(reference: origin)
        let jumped = frame.unproject(CGPoint(x: 0, y: 100))
        points[15] = TrackPoint(coordinate: jumped, timestamp: points[15].timestamp,
                                speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: 5)

        let metrics = SoccerLoadMetrics.compute(track: points, playingIntervals: [])

        XCTAssertLessThanOrEqual(metrics.topSpeedMetersPerSecond,
                                 SoccerLoadMetrics.outlierSpeedCapMetersPerSecond,
                                 "the 25 m/s glitch is rejected, not reported")
        XCTAssertEqual(metrics.topSpeedMetersPerSecond, 8, accuracy: 1.0,
                       "top speed reflects the real 8 m/s motion")
        // Sprint distance stays near the true 8 m/s × ~12 s, not inflated by the 100 m jump.
        XCTAssertLessThan(metrics.sprintDistanceMeters, 120,
                          "the teleport step is excluded from sprint distance")
    }

    // MARK: - Degenerate inputs

    func testEmptyAndSinglePointTracksReturnZero() {
        XCTAssertEqual(SoccerLoadMetrics.compute(track: [], playingIntervals: []), .zero)
        let single = [TrackPoint(coordinate: origin, timestamp: start,
                                 speedMetersPerSecond: 5, courseDegrees: -1, horizontalAccuracy: 5)]
        XCTAssertEqual(SoccerLoadMetrics.compute(track: single, playingIntervals: []), .zero)
    }
}
