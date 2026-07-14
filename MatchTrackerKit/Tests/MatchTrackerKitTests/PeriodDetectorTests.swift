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
        let projector = FieldProjector(rectangle: rectangle)
        let track = halftimeMatch(rect: rectangle)

        let events = PeriodDetector.detectPeriods(track: track, events: [], projector: projector,
                                                  configuration: PeriodDetectorConfiguration())

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
        let projector = FieldProjector(rectangle: rectangle)
        let track = halftimeMatch(rect: rectangle)

        let existing = [MatchEvent(kind: .periodStart, date: start, source: .manual)]
        let events = PeriodDetector.detectPeriods(track: track, events: existing, projector: projector,
                                                  configuration: PeriodDetectorConfiguration())
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

        let events = PeriodDetector.detectPeriods(track: points, events: [], projector: nil,
                                                  configuration: PeriodDetectorConfiguration())
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
        let projector = FieldProjector(rectangle: rectangle)
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
        let events = PeriodDetector.detectPeriods(track: points, events: [], projector: projector,
                                                  configuration: configuration)

        XCTAssertEqual(events.filter { $0.kind == .periodEnd }.count, 3)
        XCTAssertEqual(events.filter { $0.kind == .periodStart }.count, 3)
        XCTAssertTrue(events.allSatisfy { $0.source == .automatic })

        let ends = events.filter { $0.kind == .periodEnd }.map { $0.date.timeIntervalSince(start) }.sorted()
        for (detected, expected) in zip(ends, breakStarts) {
            XCTAssertEqual(detected, expected, accuracy: 60)
        }
    }
}
