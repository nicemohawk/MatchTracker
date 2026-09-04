import XCTest
import CoreGraphics
@testable import MatchTrackerKit

/// Tests for geometry-first automatic substitution detection. A synthetic 105×68 pitch and its
/// projector back every case; points are placed in normalized field space and mapped to world
/// coordinates (the exact inverse of `FieldProjector.normalizedPoint`).
final class AutoSubDetectorTests: XCTestCase {

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)
    private lazy var rect = makeOrientedRectangle(center: fieldCenter, lengthMeters: 105, widthMeters: 68, headingDegrees: 0)
    private lazy var projector = FieldProjector(rectangle: rect)

    private let epoch = Date(timeIntervalSince1970: 0)

    /// Place a normalized field point back into world coordinates.
    private func place(x: Double, y: Double) -> Coordinate2D {
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

    /// A coordinate `meters` beyond the near sideline (crossing the short-axis touchline).
    private func outside(meters: Double) -> Coordinate2D {
        place(x: 0.5, y: 1.0 + meters / rect.widthMeters)
    }

    /// A track point at time `t` (seconds from epoch).
    private func point(_ coordinate: Coordinate2D, t: Double, accuracy: Double = 5) -> TrackPoint {
        TrackPoint(coordinate: coordinate, timestamp: epoch.addingTimeInterval(t),
                   speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: accuracy)
    }

    private func detector(initiallyOnPitch: Bool = true) -> AutoSubDetector {
        AutoSubDetector(projector: projector, configuration: AutoSubDetectorConfiguration(),
                        initiallyOnPitch: initiallyOnPitch)
    }

    // MARK: - Live processing

    // (a) A genuine 45 s excursion 10 m beyond the touchline yields one subOut dated at the exit.
    func testExitBeyondTouchlineEmitsSubOutDatedAtExit() {
        let detector = detector()
        var events: [MatchEvent] = []
        // On pitch t = 0...9.
        for t in stride(from: 0.0, through: 9.0, by: 1.0) {
            if let e = detector.process(point: point(place(x: 0.5, y: 0.5), t: t), heartRate: nil) { events.append(e) }
        }
        // 10 m outside, t = 10...55 (45 s).
        for t in stride(from: 10.0, through: 55.0, by: 1.0) {
            if let e = detector.process(point: point(outside(meters: 10), t: t), heartRate: nil) { events.append(e) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .subOut)
        XCTAssertEqual(events.first?.source, .automatic)
        XCTAssertEqual(events.first?.date, epoch.addingTimeInterval(10), "dated at the moment of exit, not detection")
    }

    // (b) A brief 15 s corner-taking excursion 3 m outside stays in the ambiguous band → no event.
    func testShortShallowExcursionEmitsNothing() {
        let detector = detector()
        var events: [MatchEvent] = []
        for t in stride(from: 0.0, through: 9.0, by: 1.0) {
            if let e = detector.process(point: point(place(x: 0.5, y: 0.5), t: t), heartRate: nil) { events.append(e) }
        }
        for t in stride(from: 10.0, through: 24.0, by: 1.0) {   // 15 s only, 3 m out
            if let e = detector.process(point: point(outside(meters: 3), t: t), heartRate: nil) { events.append(e) }
        }
        for t in stride(from: 25.0, through: 34.0, by: 1.0) {   // back on pitch
            if let e = detector.process(point: point(place(x: 0.5, y: 0.5), t: t), heartRate: nil) { events.append(e) }
        }
        XCTAssertTrue(events.isEmpty)
    }

    // (c) Re-entry after a bench spell yields a subIn dated at the re-entry moment.
    func testReentryEmitsSubInDatedAtReentry() {
        let detector = detector(initiallyOnPitch: false)
        var events: [MatchEvent] = []
        for t in stride(from: 0.0, through: 9.0, by: 1.0) {   // off pitch, 10 m out
            if let e = detector.process(point: point(outside(meters: 10), t: t), heartRate: nil) { events.append(e) }
        }
        for t in stride(from: 10.0, through: 30.0, by: 1.0) { // back inside for 20 s
            if let e = detector.process(point: point(place(x: 0.5, y: 0.5), t: t), heartRate: nil) { events.append(e) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .subIn)
        XCTAssertEqual(events.first?.source, .automatic)
        XCTAssertEqual(events.first?.date, epoch.addingTimeInterval(10))
    }

    // (d) The explicit non-goal: a keeper standing on the goal line INSIDE the pitch for 10 min
    // (zero movement) must never be read as a substitution.
    func testStationaryKeeperInsidePitchEmitsNothing() {
        let detector = detector()
        var events: [MatchEvent] = []
        let goalLine = place(x: 0.02, y: 0.5)   // just inside the goal-line end, centered
        for t in stride(from: 0.0, through: 600.0, by: 2.0) {
            if let e = detector.process(point: point(goalLine, t: t), heartRate: nil) { events.append(e) }
        }
        XCTAssertTrue(events.isEmpty, "standing still inside the pitch is never a sub")
    }

    // (e) Boundary jitter with brief clearly-off spikes never dwells long enough → no flapping.
    func testBoundaryJitterDoesNotFlap() {
        let detector = detector()
        var events: [MatchEvent] = []
        for i in 0..<200 {
            let t = Double(i)
            // Every 4th sample spikes 8 m out; the samples between are inside, cancelling the
            // candidate before the exit dwell can ever elapse.
            let coordinate = (i % 4 == 0) ? outside(meters: 8) : place(x: 0.5, y: 0.5)
            if let e = detector.process(point: point(coordinate, t: t), heartRate: nil) { events.append(e) }
        }
        XCTAssertTrue(events.isEmpty)
    }

    // (f) A manual subOut mutes auto detection during the cooldown window.
    func testManualSubOutSuppressesAutoDuringCooldown() {
        let detector = detector()
        // Manual sub-out at t = 0 → state offPitch, cooldown until t = 60.
        detector.recordManualEvent(MatchEvent(kind: .subOut, date: epoch, source: .manual))
        var events: [MatchEvent] = []
        // Player is actually inside the pitch the whole time (manual was premature). Without the
        // cooldown this would confirm a subIn ~t=16; suppression must swallow it.
        for t in stride(from: 1.0, through: 40.0, by: 1.0) {
            if let e = detector.process(point: point(place(x: 0.5, y: 0.5), t: t), heartRate: nil) { events.append(e) }
        }
        XCTAssertTrue(events.isEmpty, "auto output is suppressed inside the manual-override cooldown")
    }

    // (g) Offline reconciliation over a full synthetic match with one bench spell returns exactly
    // an automatic subOut + subIn pair.
    func testOfflineDetectEventsFindsOneBenchSpell() {
        var track: [TrackPoint] = []
        // On pitch 0...300.
        for t in stride(from: 0.0, through: 300.0, by: 5.0) {
            track.append(point(place(x: 0.5, y: 0.5), t: t))
        }
        // Benched (10 m out) 305...420.
        for t in stride(from: 305.0, through: 420.0, by: 5.0) {
            track.append(point(outside(meters: 10), t: t))
        }
        // Back on pitch 425...720.
        for t in stride(from: 425.0, through: 720.0, by: 5.0) {
            track.append(point(place(x: 0.5, y: 0.5), t: t))
        }

        let events = AutoSubDetector.detectEvents(track: track, projector: projector,
                                                  existingEvents: [],
                                                  configuration: AutoSubDetectorConfiguration())
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.kind), [.subOut, .subIn])
        XCTAssertTrue(events.allSatisfy { $0.source == .automatic })
        XCTAssertEqual(events[0].date, epoch.addingTimeInterval(305), "subOut dated at bench start")
        XCTAssertEqual(events[1].date, epoch.addingTimeInterval(425), "subIn dated at re-entry")
    }

    // (h) Low-accuracy fixes are blind: an "exit" made entirely of loose fixes triggers nothing.
    func testLowAccuracyFixesDoNotTrigger() {
        let detector = detector()
        var events: [MatchEvent] = []
        for t in stride(from: 0.0, through: 9.0, by: 1.0) {
            if let e = detector.process(point: point(place(x: 0.5, y: 0.5), t: t), heartRate: nil) { events.append(e) }
        }
        // 45 s "outside" but every fix is worse than maximumFixAccuracy (30 > 20 m).
        for t in stride(from: 10.0, through: 55.0, by: 1.0) {
            if let e = detector.process(point: point(outside(meters: 10), t: t, accuracy: 30), heartRate: nil) { events.append(e) }
        }
        XCTAssertTrue(events.isEmpty)
    }

    // (i) A MatchEvent JSON without a "source" key decodes as .manual (wire back-compat).
    func testMatchEventDecodesMissingSourceAsManual() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555","kind":"flag","date":"1970-01-01T00:01:00Z"}
        """
        let event = try MatchTrackerJSON.decoder().decode(MatchEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.source, .manual)
        XCTAssertEqual(event.kind, .flag)

        // And a freshly encoded event always carries the key going forward.
        let data = try MatchTrackerJSON.encoder().encode(MatchEvent(kind: .subOut, date: epoch, source: .automatic))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "automatic")
    }
}
