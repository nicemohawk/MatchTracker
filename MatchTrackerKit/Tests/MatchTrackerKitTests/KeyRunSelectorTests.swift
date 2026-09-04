import XCTest
import CoreGraphics
@testable import MatchTrackerKit

final class KeyRunSelectorTests: XCTestCase {

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)
    private let start = Date(timeIntervalSince1970: 0)

    private func rect() -> OrientedRectangle {
        makeOrientedRectangle(center: fieldCenter, lengthMeters: 100, widthMeters: 64, headingDegrees: 0)
    }

    /// Place a normalized field point (x along the long axis, y along the short) into world coords.
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

    /// Accumulates a track and returns run segments whose endpoints sit at chosen normalized
    /// positions, with distance/peak/intensity set directly (the selector reads those fields, not
    /// the raw track), so every category can be exercised deterministically.
    private final class Builder {
        let rect: OrientedRectangle
        let start: Date
        let place: (OrientedRectangle, Double, Double) -> Coordinate2D
        private(set) var track: [TrackPoint] = []

        init(rect: OrientedRectangle, start: Date, place: @escaping (OrientedRectangle, Double, Double) -> Coordinate2D) {
            self.rect = rect
            self.start = start
            self.place = place
        }

        @discardableResult
        func addRun(from: (Double, Double), to: (Double, Double), intensity: RunIntensity,
                    distance: Double, peak: Double, at offset: Double, duration: Double) -> RunSegment {
            let lower = track.count
            track.append(TrackPoint(coordinate: place(rect, from.0, from.1),
                                    timestamp: start.addingTimeInterval(offset),
                                    speedMetersPerSecond: peak, courseDegrees: -1, horizontalAccuracy: 5))
            track.append(TrackPoint(coordinate: place(rect, to.0, to.1),
                                    timestamp: start.addingTimeInterval(offset + duration),
                                    speedMetersPerSecond: peak, courseDegrees: -1, horizontalAccuracy: 5))
            return RunSegment(
                interval: DateInterval(start: start.addingTimeInterval(offset),
                                       end: start.addingTimeInterval(offset + duration)),
                distanceMeters: distance, peakSpeed: peak, averageSpeed: peak * 0.7,
                intensity: intensity, pointRange: lower..<(lower + 2)
            )
        }
    }

    private func keyRun(_ category: KeyRunCategory, in keyRuns: [KeyRun]) -> KeyRun? {
        keyRuns.first { $0.category == category }
    }

    // MARK: - Every category, one segment each

    func testSelectsEveryCategoryWithSingleAttackDirection() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)

        // First half attacks toward +x (sprint bias positive); no sub events -> on-pitch 0..3600,
        // halves split at the on-pitch midpoint (1800 s).
        let longest = builder.addRun(from: (0.50, 0.50), to: (0.55, 0.50), intensity: .jog,
                                     distance: 120, peak: 3.0, at: 100, duration: 40)
        let fastest = builder.addRun(from: (0.40, 0.30), to: (0.45, 0.30), intensity: .sprint,
                                     distance: 40, peak: 8.0, at: 300, duration: 20)
        let attack  = builder.addRun(from: (0.20, 0.50), to: (0.80, 0.50), intensity: .sprint,
                                     distance: 65, peak: 6.0, at: 600, duration: 30)
        let recovery = builder.addRun(from: (0.85, 0.50), to: (0.25, 0.50), intensity: .run,
                                      distance: 62, peak: 4.5, at: 900, duration: 30)
        let late    = builder.addRun(from: (0.50, 0.40), to: (0.55, 0.40), intensity: .sprint,
                                     distance: 45, peak: 7.0, at: 3000, duration: 20)

        let runs = [longest, fastest, attack, recovery, late]
        let projector = FieldProjector(rectangle: rectangle)
        let keyRuns = KeyRunSelector.select(runs: runs, track: builder.track, projector: projector,
                                            events: [], matchStart: start,
                                            matchEnd: start.addingTimeInterval(3600))

        XCTAssertEqual(keyRuns.count, 5, "one run per category")
        XCTAssertEqual(keyRun(.longest, in: keyRuns)?.segment.id, longest.id)
        XCTAssertEqual(keyRun(.fastestSprint, in: keyRuns)?.segment.id, fastest.id)
        XCTAssertEqual(keyRun(.deepestAttack, in: keyRuns)?.segment.id, attack.id)
        XCTAssertEqual(keyRun(.longestRecovery, in: keyRuns)?.segment.id, recovery.id)
        XCTAssertEqual(keyRun(.lateBurst, in: keyRuns)?.segment.id, late.id)

        // Results come back in category order.
        XCTAssertEqual(keyRuns.map(\.category),
                       [.longest, .fastestSprint, .deepestAttack, .longestRecovery, .lateBurst])
    }

    // MARK: - Dedup: a segment can win only one category

    func testOneSegmentWinsOneCategoryNextBestFills() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)

        // The single best run is both the longest AND the fastest sprint; a runner-up sprint must
        // fill the fastestSprint slot instead of duplicating the winner.
        let best = builder.addRun(from: (0.45, 0.50), to: (0.50, 0.50), intensity: .sprint,
                                  distance: 130, peak: 9.0, at: 200, duration: 30)
        let runnerUp = builder.addRun(from: (0.50, 0.45), to: (0.55, 0.45), intensity: .sprint,
                                      distance: 50, peak: 7.0, at: 500, duration: 20)

        let projector = FieldProjector(rectangle: rectangle)
        let keyRuns = KeyRunSelector.select(runs: [best, runnerUp], track: builder.track,
                                            projector: projector, events: [], matchStart: start,
                                            matchEnd: start.addingTimeInterval(3600))

        XCTAssertEqual(keyRun(.longest, in: keyRuns)?.segment.id, best.id)
        XCTAssertEqual(keyRun(.fastestSprint, in: keyRuns)?.segment.id, runnerUp.id,
                       "best already claimed .longest, so the next-best sprint fills .fastestSprint")

        // No segment appears twice.
        let ids = keyRuns.map(\.segment.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - Nil projector fallback

    func testNilProjectorOmitsDirectionAwareCategories() {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)
        let runs = [
            builder.addRun(from: (0.50, 0.50), to: (0.55, 0.50), intensity: .jog,
                           distance: 120, peak: 3.0, at: 100, duration: 40),
            builder.addRun(from: (0.40, 0.30), to: (0.45, 0.30), intensity: .sprint,
                           distance: 40, peak: 8.0, at: 300, duration: 20),
            builder.addRun(from: (0.50, 0.40), to: (0.55, 0.40), intensity: .sprint,
                           distance: 45, peak: 7.0, at: 3000, duration: 20),
            // A big directional run that WOULD win deepestAttack if a projector were present.
            builder.addRun(from: (0.20, 0.50), to: (0.80, 0.50), intensity: .run,
                           distance: 60, peak: 4.5, at: 600, duration: 30)
        ]

        let keyRuns = KeyRunSelector.select(runs: runs, track: builder.track, projector: nil,
                                            events: [], matchStart: start,
                                            matchEnd: start.addingTimeInterval(3600))
        let categories = Set(keyRuns.map(\.category))
        XCTAssertEqual(categories, [.longest, .fastestSprint, .lateBurst])
        XCTAssertFalse(categories.contains(.deepestAttack))
        XCTAssertFalse(categories.contains(.longestRecovery))
    }

    // MARK: - Direction inference with a second-half flip

    func testDirectionInferenceFlipsInSecondHalf() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)

        // Explicit two periods. First half attacks +x, second half attacks -x.
        let firstHalfSprint  = builder.addRun(from: (0.25, 0.50), to: (0.75, 0.50), intensity: .sprint,
                                              distance: 80, peak: 8.0, at: 200, duration: 30)
        let secondHalfSprint = builder.addRun(from: (0.75, 0.50), to: (0.25, 0.50), intensity: .sprint,
                                              distance: 40, peak: 7.0, at: 2000, duration: 30)
        // Deep run in the second half traveling toward -x: attack because 2nd-half attacks -x.
        let secondHalfDeep   = builder.addRun(from: (0.90, 0.50), to: (0.20, 0.50), intensity: .run,
                                              distance: 50, peak: 4.5, at: 2500, duration: 30)
        // Deep run in the first half traveling toward -x: recovery because 1st-half attacks +x.
        let firstHalfBack    = builder.addRun(from: (0.80, 0.50), to: (0.20, 0.50), intensity: .run,
                                              distance: 45, peak: 4.2, at: 700, duration: 30)

        let events = [
            MatchEvent(kind: .periodStart, date: start, source: .manual),
            MatchEvent(kind: .periodEnd, date: start.addingTimeInterval(1700), source: .manual),
            MatchEvent(kind: .periodStart, date: start.addingTimeInterval(1900), source: .manual),
            MatchEvent(kind: .periodEnd, date: start.addingTimeInterval(3600), source: .manual)
        ]

        let runs = [firstHalfSprint, secondHalfSprint, secondHalfDeep, firstHalfBack]
        let projector = FieldProjector(rectangle: rectangle)
        let keyRuns = KeyRunSelector.select(runs: runs, track: builder.track, projector: projector,
                                            events: events, matchStart: start,
                                            matchEnd: start.addingTimeInterval(3600))

        XCTAssertEqual(keyRun(.deepestAttack, in: keyRuns)?.segment.id, secondHalfDeep.id,
                       "a -x run in the second half is the deepest attack once the flip is applied")
        XCTAssertEqual(keyRun(.longestRecovery, in: keyRuns)?.segment.id, firstHalfBack.id,
                       "a -x run in the first half is a recovery run")
    }

    // MARK: - Adaptive scoring: event linkage beats raw magnitude

    func testEventLinkedRunOutranksLongerUnlinkedRun() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)

        // A much longer, faster run with no event near it...
        let longUnlinked = builder.addRun(from: (0.50, 0.50), to: (0.55, 0.50), intensity: .sprint,
                                          distance: 200, peak: 5.0, at: 100, duration: 40)
        // ...versus a modest run that ends 10 s before the wearer scores.
        let eventLinked = builder.addRun(from: (0.40, 0.50), to: (0.45, 0.50), intensity: .run,
                                         distance: 60, peak: 4.0, at: 600, duration: 30)
        let events = [MatchEvent(kind: .goalMine, date: start.addingTimeInterval(640))]

        let scored = KeyRunSelector.scoredSelection(
            runs: [longUnlinked, eventLinked], track: builder.track, projector: nil,
            events: events, matchStart: start, matchEnd: start.addingTimeInterval(3600),
            baselines: nil
        )

        XCTAssertEqual(scored.first?.id, eventLinked.id, "the goal-feeding run leads")
        let linkedScore = scored.first { $0.id == eventLinked.id }?.score ?? 0
        let unlinkedScore = scored.first { $0.id == longUnlinked.id }?.score ?? 0
        XCTAssertGreaterThan(linkedScore, unlinkedScore)
        XCTAssertEqual(scored.first?.reasons.first, "Just before your goal")
        // Category back-compat: the longer run still carries its legacy label, reasons never empty.
        XCTAssertEqual(scored.first { $0.id == longUnlinked.id }?.category, .longest)
        XCTAssertTrue(scored.allSatisfy { !$0.reasons.isEmpty })
    }

    // MARK: - Adaptive scoring: novelty flips selection when baselines shift

    func testNoveltyBaselinesFlipTheWinner() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)

        // Two equally match-magnitude runs: one is the fastest, one is the longest.
        let runFast = builder.addRun(from: (0.40, 0.50), to: (0.45, 0.50), intensity: .sprint,
                                     distance: 50, peak: 9.0, at: 200, duration: 20)
        let runFar  = builder.addRun(from: (0.30, 0.50), to: (0.35, 0.50), intensity: .run,
                                     distance: 150, peak: 4.0, at: 300, duration: 20)
        let runs = [runFast, runFar]
        let end = start.addingTimeInterval(3600)

        // Baselines where a 9 m/s peak is wildly unusual but 150 m is normal -> the fast run wins.
        let speedIsNovel = RunBaselines(meanDistance: 150, stdDistance: 30,
                                        meanPeakSpeed: 5, stdPeakSpeed: 1)
        let bySpeed = KeyRunSelector.scoredSelection(
            runs: runs, track: builder.track, projector: nil, events: [],
            matchStart: start, matchEnd: end, baselines: speedIsNovel
        )
        XCTAssertEqual(bySpeed.first?.id, runFast.id, "an unusually fast run leads under speed baselines")

        // Shift the baselines so distance is the unusual axis -> the long run wins instead.
        let distanceIsNovel = RunBaselines(meanDistance: 50, stdDistance: 20,
                                           meanPeakSpeed: 9, stdPeakSpeed: 1)
        let byDistance = KeyRunSelector.scoredSelection(
            runs: runs, track: builder.track, projector: nil, events: [],
            matchStart: start, matchEnd: end, baselines: distanceIsNovel
        )
        XCTAssertEqual(byDistance.first?.id, runFar.id, "novelty flips the winner when baselines shift")
    }

    // MARK: - Adaptive scoring: diversity avoids near-duplicates

    func testDiversitySkipsNearDuplicateRuns() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)

        // Two long attacking runs from the same spot, same phase of the match — near-duplicates.
        let twinA = builder.addRun(from: (0.20, 0.50), to: (0.80, 0.50), intensity: .sprint,
                                   distance: 100, peak: 8.0, at: 200, duration: 30)
        let twinB = builder.addRun(from: (0.20, 0.50), to: (0.80, 0.50), intensity: .sprint,
                                   distance: 100, peak: 8.0, at: 260, duration: 30)
        // A distinct run elsewhere on the pitch that also feeds a goal.
        let diverse = builder.addRun(from: (0.80, 0.90), to: (0.85, 0.90), intensity: .sprint,
                                     distance: 40, peak: 7.0, at: 1500, duration: 20)
        let events = [MatchEvent(kind: .goalMine, date: start.addingTimeInterval(1530))]

        let projector = FieldProjector(rectangle: rectangle)
        let scored = KeyRunSelector.scoredSelection(
            runs: [twinA, twinB, diverse], track: builder.track, projector: projector,
            events: events, matchStart: start, matchEnd: start.addingTimeInterval(3600),
            baselines: nil, limit: 2
        )

        let ids = Set(scored.map(\.id))
        XCTAssertEqual(scored.count, 2)
        XCTAssertTrue(ids.contains(diverse.id), "the distinct run is surfaced")
        XCTAssertNotEqual(ids.contains(twinA.id), ids.contains(twinB.id),
                          "only one of the two near-identical runs is picked")
    }

    // MARK: - Adaptive scoring: deterministic ordering

    func testScoredSelectionIsDeterministic() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)
        let runs = [
            builder.addRun(from: (0.20, 0.50), to: (0.80, 0.50), intensity: .sprint,
                           distance: 90, peak: 8.0, at: 200, duration: 30),
            builder.addRun(from: (0.80, 0.40), to: (0.30, 0.40), intensity: .run,
                           distance: 70, peak: 4.5, at: 900, duration: 30),
            builder.addRun(from: (0.50, 0.60), to: (0.55, 0.60), intensity: .sprint,
                           distance: 45, peak: 7.0, at: 3000, duration: 20)
        ]
        let projector = FieldProjector(rectangle: rectangle)
        func run() -> [ScoredRun] {
            KeyRunSelector.scoredSelection(runs: runs, track: builder.track, projector: projector,
                                           events: [], matchStart: start,
                                           matchEnd: start.addingTimeInterval(3600), baselines: nil)
        }
        let first = run(), second = run()
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.score), second.map(\.score))
    }

    // MARK: - Adaptive scoring: a quiet match returns fewer, not filler

    func testQuietMatchReturnsFewerThanLimit() throws {
        let rectangle = rect()
        let builder = Builder(rect: rectangle, start: start, place: place)
        // Five interchangeable short jogs from the same spot — nothing individually interesting.
        var runs: [RunSegment] = []
        for index in 0..<5 {
            runs.append(builder.addRun(from: (0.50, 0.50), to: (0.52, 0.50), intensity: .jog,
                                       distance: 25, peak: 3.0,
                                       at: 100 + Double(index) * 30, duration: 10))
        }
        let projector = FieldProjector(rectangle: rectangle)
        let scored = KeyRunSelector.scoredSelection(
            runs: runs, track: builder.track, projector: projector, events: [],
            matchStart: start, matchEnd: start.addingTimeInterval(3600), baselines: nil, limit: 6
        )

        XCTAssertLessThan(scored.count, runs.count, "near-duplicate quiet runs get trimmed")
        XCTAssertLessThan(scored.count, 6, "a quiet match doesn't pad up to the limit")
        XCTAssertTrue(scored.allSatisfy { !$0.reasons.isEmpty })
    }
}
