import XCTest
import CoreGraphics
@testable import MatchTrackerKit

final class PeriodDetectorTests: XCTestCase {

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)
    private let start = Date(timeIntervalSince1970: 0)

    private func rect() -> OrientedRectangle {
        makeOrientedRectangle(center: fieldCenter, lengthMeters: 100, widthMeters: 64, headingDegrees: 0)
    }

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

    /// A moving on-pitch fix at the given time offset (seconds).
    private func playingPoint(_ rect: OrientedRectangle, at offset: Double, seed: Double) -> TrackPoint {
        let x = 0.5 + 0.2 * sin(seed * 0.3)
        let y = 0.5 + 0.15 * cos(seed * 0.2)
        return TrackPoint(coordinate: place(rect, x: x, y: y), timestamp: start.addingTimeInterval(offset),
                          speedMetersPerSecond: 2.5, courseDegrees: -1, horizontalAccuracy: 8)
    }

    /// Synthetic two-period match: 30 min play, 12 min off-pitch halftime, 30 min play.
    private func halftimeMatch(rect: OrientedRectangle) -> [TrackPoint] {
        var points: [TrackPoint] = []
        var seed = 0.0

        // First half: 0 – 1800 s, moving on-pitch, 3 s cadence.
        for offset in stride(from: 0.0, to: 1800.0, by: 3.0) {
            points.append(playingPoint(rect, at: offset, seed: seed)); seed += 1
        }
        // Halftime: 1800 – 2520 s (12 min), standing well beyond the far touchline, 10 s cadence.
        let benchCoordinate = place(rect, x: 1.6, y: 0.5)   // ~60 m past the end line
        for offset in stride(from: 1800.0, through: 2520.0, by: 10.0) {
            points.append(TrackPoint(coordinate: benchCoordinate, timestamp: start.addingTimeInterval(offset),
                                     speedMetersPerSecond: 0.0, courseDegrees: -1, horizontalAccuracy: 8))
        }
        // Second half: 2523 – 4323 s, moving on-pitch again.
        for offset in stride(from: 2523.0, to: 4323.0, by: 3.0) {
            points.append(playingPoint(rect, at: offset, seed: seed)); seed += 1
        }
        return points
    }

    func testFindsTwelveMinuteHalftimeGap() throws {
        let rectangle = rect()
        let track = halftimeMatch(rect: rectangle)

        let events = PeriodDetector.detectPeriods(track: track, events: [])

        XCTAssertEqual(events.count, 2, "one halftime break -> a periodEnd/periodStart pair")
        let end = try XCTUnwrap(events.first { $0.kind == .periodEnd })
        let resume = try XCTUnwrap(events.first { $0.kind == .periodStart })
        XCTAssertEqual(end.source, .automatic)
        XCTAssertEqual(resume.source, .automatic)

        XCTAssertEqual(end.date.timeIntervalSince(start), 1800, accuracy: 60, "period ends at the start of the break")
        XCTAssertEqual(resume.date.timeIntervalSince(start), 2520, accuracy: 60, "period resumes at the end of the break")
    }

    func testReturnsEmptyWhenPeriodEventsExist() {
        let rectangle = rect()
        let track = halftimeMatch(rect: rectangle)

        let existing = [MatchEvent(kind: .periodStart, date: start, source: .manual)]
        let events = PeriodDetector.detectPeriods(track: track, events: existing)
        XCTAssertTrue(events.isEmpty, "existing period markers suppress auto-detection")
    }

    func testDetectsHalftimeFromCoverageHoleWithoutProjector() {
        let rectangle = rect()
        var points: [TrackPoint] = []
        var seed = 0.0
        for offset in stride(from: 0.0, to: 1800.0, by: 3.0) {
            points.append(playingPoint(rectangle, at: offset, seed: seed)); seed += 1
        }
        // No fixes at all during a 12-minute GPS dropout (1800 – 2520 s).
        for offset in stride(from: 2520.0, to: 4320.0, by: 3.0) {
            points.append(playingPoint(rectangle, at: offset, seed: seed)); seed += 1
        }

        let events = PeriodDetector.detectPeriods(track: points, events: [])
        XCTAssertEqual(events.count, 2, "the coverage hole alone marks the halftime break")
        let endOffset = events.first { $0.kind == .periodEnd }?.date.timeIntervalSince(start) ?? -1
        let resumeOffset = events.first { $0.kind == .periodStart }?.date.timeIntervalSince(start) ?? -1
        XCTAssertEqual(endOffset, 1800, accuracy: 60)
        XCTAssertEqual(resumeOffset, 2520, accuracy: 60)
    }

    // MARK: - Pickup sessions (expectedPeriods == 0)

    /// A ~2 h pickup game with three 6-minute rest breaks and no fixed halves. With
    /// `expectedPeriods == 0` every qualifying break becomes a boundary, not just one midpoint gap.
    func testPickupSessionReturnsAllQualifyingBreaks() throws {
        let rectangle = rect()
        let benchCoordinate = place(rectangle, x: 1.6, y: 0.5)   // well past the end line

        var points: [TrackPoint] = []
        var seed = 0.0
        var offset = 0.0
        // Four 20-minute playing blocks separated by three 6-minute (360 s) breaks.
        let breakStarts = [1200.0, 2760.0, 4320.0]
        for block in 0..<4 {
            let playEnd = offset + 1200
            while offset < playEnd {
                points.append(playingPoint(rectangle, at: offset, seed: seed)); seed += 1; offset += 3
            }
            if block < 3 {
                let breakEnd = offset + 360
                while offset < breakEnd {
                    points.append(TrackPoint(coordinate: benchCoordinate, timestamp: start.addingTimeInterval(offset),
                                             speedMetersPerSecond: 0.0, courseDegrees: -1, horizontalAccuracy: 8))
                    offset += 10
                }
            }
        }

        var configuration = PeriodDetectorConfiguration()
        configuration.expectedPeriods = 0
        let events = PeriodDetector.detectPeriods(track: points, events: [], configuration: configuration)

        XCTAssertEqual(events.filter { $0.kind == .periodEnd }.count, 3)
        XCTAssertEqual(events.filter { $0.kind == .periodStart }.count, 3)
        XCTAssertTrue(events.allSatisfy { $0.source == .automatic })

        let ends = events.filter { $0.kind == .periodEnd }.map { $0.date.timeIntervalSince(start) }.sorted()
        for (detected, expected) in zip(ends, breakStarts) {
            XCTAssertEqual(detected, expected, accuracy: 60)
        }
    }

    // MARK: - Implausible halves

    /// Alternating stretches of play (2.5 m/s) and standing (0), in minutes.
    private func match(_ stretches: [(minutes: Double, playing: Bool)]) -> [TrackPoint] {
        var points: [TrackPoint] = []
        var offset = 0.0
        for stretch in stretches {
            let end = offset + stretch.minutes * 60
            while offset < end {
                var point = playingPoint(rect(), at: offset, seed: offset)
                if !stretch.playing { point.speedMetersPerSecond = 0 }
                points.append(point)
                offset += 2
            }
        }
        return points
    }

    private func detectedMinutes(_ track: [TrackPoint]) -> [Int] {
        PeriodDetector.detectPeriods(track: track, events: []).map {
            Int(($0.date.timeIntervalSince(start) / 60).rounded())
        }
    }

    func testEarlyAndLateBreaksAreNotHalftime() {
        XCTAssertEqual(detectedMinutes(match([(3, true), (5, false), (71, true)])), [])
        XCTAssertEqual(detectedMinutes(match([(79, true), (6, false), (3, true)])), [])
    }

    func testStandingAboutBeforeAndAfterIsNotPlayingTime() {
        // Twenty minutes of waiting first would put the true halftime at two thirds of the recording.
        XCTAssertEqual(detectedMinutes(match([(20, false), (30, true), (8, false), (30, true), (10, false)])), [50, 58])
    }

    func testBreakTooShortOrTooLongIsNotHalftime() {
        XCTAssertEqual(detectedMinutes(match([(40, true), (2, false), (40, true)])), [])
        XCTAssertEqual(detectedMinutes(match([(40, true), (30, false), (40, true)])), [])
    }

    func testAJogInTheMiddleDoesNotEndHalftime() {
        var track = match([(40, true), (12, false), (40, true)])
        for index in track.indices where (45 * 60..<46 * 60).contains(Int(track[index].timestamp.timeIntervalSince(start))) {
            track[index].speedMetersPerSecond = 1.5
        }
        XCTAssertEqual(detectedMinutes(track), [40, 52])
    }

    func testMarkedHalftimeBeatsDetectionUnlessItIsImplausible() {
        let track = match([(40, true), (10, false), (40, true)])
        let interval = DateInterval(start: start, duration: 90 * 60)
        func marks(_ end: Double, _ resume: Double, _ source: MatchEventSource = .manual) -> [MatchEvent] {
            [MatchEvent(kind: .periodEnd, date: start.addingTimeInterval(end * 60), source: source),
             MatchEvent(kind: .periodStart, date: start.addingTimeInterval(resume * 60), source: source)]
        }
        func halftimeStart(_ events: [MatchEvent]) -> Double? {
            PeriodDetector.halftime(track: track, events: events, interval: interval)
                .map { $0.start.timeIntervalSince(start) / 60 }
        }
        XCTAssertEqual(try XCTUnwrap(halftimeStart(marks(43, 49))), 43, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(halftimeStart(marks(3, 8))), 40, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(halftimeStart(marks(30, 35, .automatic))), 40, accuracy: 1)
    }
}
