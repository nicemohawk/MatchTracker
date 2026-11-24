import XCTest
@testable import MatchTrackerKit

final class PitchPictureTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func heat(_ zones: [(across: Double, up: Double, seconds: Double)]) -> PitchHeat {
        PitchHeat(samples: zones.map { (PitchPoint(across: $0.across, up: $0.up), $0.seconds) })
    }

    // MARK: Sentence

    func testCentralMidfieldSentence() {
        let heat = heat([(0.5, 0.5, 60), (0.5, 0.85, 33), (0.5, 0.1, 7)])
        XCTAssertEqual(PitchSentence.describe(heat),
                       "Mostly central midfield; a third of the time in the attacking third.")
    }

    func testDefenderSentenceTalksAboutDefending() {
        let heat = heat([(0.1, 0.15, 75), (0.1, 0.5, 25)])
        XCTAssertEqual(PitchSentence.describe(heat),
                       "Mostly left back; three quarters of the time in the defensive third.")
    }

    func testRoamingWingerSentence() {
        let heat = heat([(0.9, 0.15, 30), (0.9, 0.5, 34), (0.9, 0.85, 34)])
        XCTAssertEqual(PitchSentence.describe(heat),
                       "Up and down the right; a third of the time in the attacking third.")
    }

    func testMomentsAreCounted() {
        let sentence = PitchSentence.describe(heat([(0.5, 0.5, 1)]), goals: 2, assists: 1)
        XCTAssertEqual(sentence, "Mostly central midfield; hardly any of the time in the attacking third; two goals and one assist marked.")
    }

    func testUnknownDirectionNeverSaysAttackOrSide() {
        for zone in [(0.1, 0.1), (0.9, 0.9), (0.1, 0.5), (0.5, 0.9)] {
            let sentence = PitchSentence.describe(heat([(zone.0, zone.1, 1)]), directionIsKnown: false)
            for word in ["attack", "defen", "left", "right", "front"] {
                XCTAssertFalse(sentence.lowercased().contains(word), sentence)
            }
        }
    }

    func testEmptyHeatSaysSo() {
        XCTAssertEqual(PitchSentence.describe(.empty), "No positions recorded.")
    }

    // MARK: Heat

    func testHeatKeepsAllTheTimeAndItsMiddle() throws {
        let heat = heat([(0.25, 0.75, 10), (0.75, 0.25, 30)])
        XCTAssertEqual(heat.values.reduce(0, +), 40, accuracy: 0.001)
        let average = try XCTUnwrap(heat.average)
        XCTAssertEqual(average.across, 0.625, accuracy: 0.001)
        XCTAssertEqual(average.up, 0.375, accuracy: 0.001)
    }

    func testHeatAtTheCornersStaysOnThePitch() {
        let heat = heat([(0, 0, 1), (1, 1, 1), (2, -3, 1)])
        XCTAssertEqual(heat.values.reduce(0, +), 3, accuracy: 0.001)
        XCTAssertGreaterThan(heat.values[(heat.rows - 1) * heat.columns], 0)   // own left corner
        XCTAssertGreaterThan(heat.values[heat.columns - 1], 0)                 // far right corner
    }

    func testLongAxisGridTurnsUpright() {
        // One hot cell at the far end of the long axis, on its left.
        var cells = [Double](repeating: 0, count: 6)
        cells[2] = 1
        let grid = HeatmapGrid(columns: 3, rows: 2, cells: cells)
        XCTAssertEqual(PitchHeat(grid).values, [1, 0, 0, 0, 0, 0])
        XCTAssertEqual(PitchHeat(grid, attacksTowardFarEnd: false).values, [0, 0, 0, 0, 0, 1])
        XCTAssertEqual(PitchHeat(grid).turnedAround, PitchHeat(grid, attacksTowardFarEnd: false))
        XCTAssertTrue(PitchHeat(HeatmapGrid(columns: 30, rows: 20, cells: [])).isEmpty)
    }

    // MARK: Attack direction

    func testBothHalvesAttackUp() throws {
        // A pitch running due north; the player sprints north before the break and south after.
        let frame = ENUFrame(reference: Coordinate2D(latitude: 40, longitude: -83))
        func coordinate(north: Double, east: Double) -> Coordinate2D { frame.unproject(CGPoint(x: east, y: north)) }
        let rectangle = OrientedRectangle(
            center: Coordinate2D(latitude: 40, longitude: -83), lengthMeters: 100, widthMeters: 60, headingDegrees: 0,
            corners: [])
        let projector = FieldProjector(rectangle: rectangle)
        func point(_ seconds: Double, north: Double, east: Double) -> TrackPoint {
            TrackPoint(coordinate: coordinate(north: north, east: east), timestamp: start.addingTimeInterval(seconds),
                       speedMetersPerSecond: 7, courseDegrees: 0, horizontalAccuracy: 5)
        }
        let track = [point(100, north: -30, east: 20), point(106, north: 10, east: 20),
                     point(3100, north: 30, east: -20), point(3106, north: -10, east: -20)]
        func sprint(_ from: Double, _ range: Range<Int>) -> RunSegment {
            RunSegment(interval: DateInterval(start: start.addingTimeInterval(from), duration: 6),
                       distanceMeters: 40, peakSpeed: 7, averageSpeed: 6, intensity: .sprint, pointRange: range)
        }
        let attack = AttackFrame.infer(
            track: track, runs: [sprint(100, 0..<2), sprint(3100, 2..<4)], projector: projector,
            events: [MatchEvent(kind: .periodEnd, date: start.addingTimeInterval(2400)),
                     MatchEvent(kind: .periodStart, date: start.addingTimeInterval(3000))],
            matchStart: start, matchEnd: start.addingTimeInterval(5400))
        XCTAssertTrue(attack.isKnown)
        XCTAssertEqual(attack.periods.map(\.attacksTowardFarEnd), [true, false])
        // East of a north-attacking player is their right; so is west of a south-attacking one.
        for index in [0, 2] {
            let placed = try XCTUnwrap(attack.point(for: track[index].coordinate, at: track[index].timestamp))
            XCTAssertEqual(placed.across, 0.5 + 20.0 / 60, accuracy: 0.01)
            XCTAssertEqual(placed.up, 0.2, accuracy: 0.01)
        }
    }

    func testNoEvidenceIsNotKnown() {
        let projector = FieldProjector(rectangle: OrientedRectangle(
            center: Coordinate2D(latitude: 40, longitude: -83), lengthMeters: 100, widthMeters: 60,
            headingDegrees: 0, corners: []))
        let attack = AttackFrame.infer(track: [], runs: [], projector: projector, events: [],
                                       matchStart: start, matchEnd: start.addingTimeInterval(5400))
        XCTAssertFalse(attack.isKnown)
    }

    // MARK: Periods

    func testPeriodsFromADetectedBreakAndFromTappedStarts() {
        let end = start.addingTimeInterval(5400)
        func event(_ kind: MatchEventKind, _ seconds: Double) -> MatchEvent {
            MatchEvent(kind: kind, date: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(MatchPeriods.derive(events: [], matchStart: start, matchEnd: end).map(\.duration), [5400])
        XCTAssertEqual(MatchPeriods.derive(events: [event(.periodEnd, 2400), event(.periodStart, 3000)],
                                           matchStart: start, matchEnd: end).map(\.duration), [2400, 2400])
        XCTAssertEqual(MatchPeriods.derive(events: [event(.periodStart, 300), event(.periodEnd, 2700),
                                                    event(.periodStart, 3000), event(.periodEnd, 5300)],
                                           matchStart: start, matchEnd: end).map(\.duration), [2400, 2300])
    }

    // MARK: Pitch size

    func testSmallPitchesShrinkTheirMarkings() {
        XCTAssertEqual(PitchSize.standard.markingScale, 1)
        XCTAssertEqual(PitchSize(lengthMeters: 95, widthMeters: 50).markingScale, 1)
        XCTAssertLessThan(PitchSize(lengthMeters: 55, widthMeters: 36).markingScale, 0.6)
        XCTAssertEqual(PitchSize(lengthMeters: 100, widthMeters: 100).aspectRatio, 0.95)
    }
}

final class ReplayTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var halves: [DateInterval] {
        [DateInterval(start: start, duration: 2400), DateInterval(start: start.addingTimeInterval(3100), duration: 2400)]
    }

    private func timeline(moments: [ReplayTimeline.Moment] = []) -> ReplayTimeline {
        ReplayTimeline(periods: halves, playing: [], moments: moments)
    }

    func testFillsTheVideoExactly() throws {
        let last = try XCTUnwrap(timeline().chapters.last)
        XCTAssertEqual(last.screen.upperBound, 15 - 2.8, accuracy: 1e-6)
        XCTAssertEqual(timeline().phase(at: 0), .opening(progress: 0))
        XCTAssertEqual(timeline().phase(at: 15), .closing(progress: 1))
    }

    func testTimeOnlyMovesForwardAndCoversEveryMinute() {
        let timeline = timeline(moments: [.init(interval: DateInterval(start: start.addingTimeInterval(900), duration: 6),
                                                extraScreenSeconds: 1.3)])
        var dates: [Date] = []
        for frame in 0..<450 {
            if case .playing(let index) = timeline.phase(at: Double(frame) / 30) {
                dates.append(timeline.matchDate(at: Double(frame) / 30, in: timeline.chapters[index]))
            }
        }
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertLessThan(dates.first!.timeIntervalSince(start), 60)
        XCTAssertGreaterThan(dates.last!.timeIntervalSince(start), 5440)
        XCTAssertFalse(dates.contains { (2400.0..<3100).contains($0.timeIntervalSince(start)) }, "half-time is skipped")
    }

    func testMomentsSlowTheClock() throws {
        let moment = DateInterval(start: start.addingTimeInterval(900), duration: 6)
        let timeline = timeline(moments: [.init(interval: moment, extraScreenSeconds: 1.3)])
        let screen = try XCTUnwrap(timeline.screenTime(of: moment.end)) - XCTUnwrap(timeline.screenTime(of: moment.start))
        XCTAssertGreaterThan(screen, 0.7)
        let ordinary = try XCTUnwrap(timeline.screenTime(of: start.addingTimeInterval(106)))
            - XCTUnwrap(timeline.screenTime(of: start.addingTimeInterval(100)))
        XCTAssertLessThan(ordinary, 0.03)
    }

    func testScreenTimeAndMatchDateAgree() throws {
        let timeline = timeline(moments: [.init(interval: DateInterval(start: start.addingTimeInterval(4000), duration: 20),
                                                extraScreenSeconds: 1)])
        for seconds in [10.0, 1200, 2390, 3200, 4010, 5400] {
            let date = start.addingTimeInterval(seconds)
            let screen = try XCTUnwrap(timeline.screenTime(of: date))
            let chapter = try XCTUnwrap(timeline.chapters.first { $0.screen.contains(screen) })
            XCTAssertEqual(timeline.matchDate(at: screen, in: chapter).timeIntervalSince(start), seconds, accuracy: 0.5)
        }
        XCTAssertNil(timeline.screenTime(of: start.addingTimeInterval(2700)))
    }

    func testClockCarriesOnThroughHalfTime() {
        XCTAssertEqual(timeline().playSeconds(at: start.addingTimeInterval(2700)), 2400)
        XCTAssertEqual(timeline().playSeconds(at: start.addingTimeInterval(3160)), 2460)
    }

    func testBenchRushesBy() throws {
        let playing = [DateInterval(start: start, duration: 1200)]
        let timeline = ReplayTimeline(periods: [DateInterval(start: start, duration: 2400)], playing: playing, moments: [])
        let chapter = try XCTUnwrap(timeline.chapters.first)
        let half = try XCTUnwrap(timeline.screenTime(of: start.addingTimeInterval(1200)))
        let share = (half - chapter.screen.lowerBound) / (chapter.screen.upperBound - chapter.screen.lowerBound)
        XCTAssertEqual(share, 1 / 1.15, accuracy: 0.01)
    }

    func testAHatfulOfGoalsStillLeavesRoomForTheMatch() throws {
        let goals = (0..<12).map {
            ReplayTimeline.Moment(interval: DateInterval(start: start.addingTimeInterval(Double($0) * 180 + 60), duration: 8),
                                  extraScreenSeconds: 1)
        }
        let last = try XCTUnwrap(timeline(moments: goals).chapters.last)
        XCTAssertEqual(last.screen.upperBound, 15 - 2.8, accuracy: 1e-6)
    }

    func testNothingToPlay() {
        let timeline = ReplayTimeline(periods: [], playing: [], moments: [])
        XCTAssertTrue(timeline.chapters.isEmpty)
        XCTAssertEqual(timeline.phase(at: 15), .closing(progress: 1))
    }
}
