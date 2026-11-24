import XCTest
@testable import MatchTrackerKit

final class SystemSurfaceTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)   // September 2026

    private func update(_ sequence: Int, at seconds: TimeInterval, elapsed: TimeInterval? = nil,
                        us: Int? = nil, them: Int? = nil, onPitch: Bool = true,
                        events: [MatchEventKind] = []) -> LiveMatchUpdate {
        LiveMatchUpdate(sequence: sequence, timestamp: base.addingTimeInterval(seconds),
                        elapsed: elapsed ?? seconds, heartRate: 151.6, distanceMeters: 1000, onPitch: onPitch,
                        newEvents: events.map { MatchEvent(kind: $0, date: base.addingTimeInterval(seconds)) },
                        usGoals: us, themGoals: them)
    }

    private func digest(_ day: Int, us: Int? = nil, them: Int? = nil, distance: Double? = 7000) -> MatchDigest {
        let start = base.addingTimeInterval(Double(day) * 86_400)
        var digest = MatchDigest(id: UUID(), startDate: start, endDate: start.addingTimeInterval(5400), format: .match)
        digest.goalsUs = us
        digest.goalsThem = them
        digest.distanceMeters = distance
        digest.averageHeartRate = 150
        return digest
    }

    // MARK: Links

    func testLinksRoundTrip() {
        let links: [MatchTrackerLink] = [.start, .live, .season, .latestMatch, .match(UUID()), .matchStarting(base)]
        for link in links { XCTAssertEqual(MatchTrackerLink(link.url), link) }
        XCTAssertNil(MatchTrackerLink(URL(string: "matchtracker://match/nonsense")!))
        XCTAssertNil(MatchTrackerLink(URL(string: "https://live")!))
    }

    // MARK: Live

    func testLiveStateStartsFromTheMatchStartEvent() {
        XCTAssertEqual(LiveMatchState(update(1, at: 4, elapsed: 1, events: [.matchStart])).startDate,
                       base.addingTimeInterval(4))
        XCTAssertEqual(LiveMatchState(update(1, at: 600)).startDate, base)
    }

    func testLiveStateNoticesAPauseFromTheClock() {
        var state = LiveMatchState(update(1, at: 60))
        state.apply(update(2, at: 65, elapsed: 61))
        XCTAssertTrue(state.isPaused)
        state.apply(update(3, at: 70, elapsed: 66))
        XCTAssertFalse(state.isPaused)
        XCTAssertEqual(state.clockStart, base.addingTimeInterval(4))
    }

    func testNoScoreIsNotNilNil() {
        var state = LiveMatchState(update(1, at: 60))
        XCTAssertNil(state.score)
        state.apply(update(2, at: 65, us: 1, them: 0))
        XCTAssertEqual(state.score, "1–0")
        XCTAssertEqual(state.spokenScore, "You lead 1 to 0")
        state.apply(update(3, at: 70, us: 1, them: 3))
        XCTAssertEqual(state.spokenScore, "You trail 3 to 1")
    }

    func testStatusIsUnknownUntilTheWatchSays() {
        XCTAssertEqual(LiveMatchState(startDate: base).status, "Under way")
        XCTAssertEqual(LiveMatchState(update(1, at: 60, onPitch: false)).status, "On the bench")
    }

    func testLiveStateBreakAndEnd() {
        var state = LiveMatchState(update(1, at: 60))
        let before = state
        state.apply(update(2, at: 65, events: [.periodEnd]))
        XCTAssertEqual(state.status, "Half-time")
        XCTAssertTrue(state.isNews(since: before))
        state.apply(update(3, at: 4320, us: 3, them: 1, events: [.periodStart, .matchEnd]))
        XCTAssertEqual(state.finalTitle, "Won 3–1")
        XCTAssertEqual(state.finalDetail(units: .imperial), "0.6 mi · 72 min")
        XCTAssertFalse(state.isClockRunning)
    }

    func testDriftingNumbersAreNotNews() {
        var state = LiveMatchState(update(1, at: 60))
        let before = state
        state.apply(update(2, at: 65))
        XCTAssertFalse(state.isNews(since: before))
    }

    // MARK: Snapshot

    func testSnapshotOfNothing() {
        let snapshot = WidgetSnapshot.make(from: [])
        XCTAssertNil(snapshot.lastMatch)
        XCTAssertNil(snapshot.season)
        XCTAssertEqual(snapshot.spokenLastMatch, "You haven't recorded a match yet.")
    }

    func testSnapshotTakesTheLatestMatchAndDropsHeartRate() {
        let latest = digest(9, us: 3, them: 1)
        let snapshot = WidgetSnapshot.make(from: [digest(2), latest, digest(5)], now: base)
        XCTAssertEqual(snapshot.lastMatch?.id, latest.id)
        XCTAssertEqual(snapshot.recent.map(\.startDate), snapshot.recent.map(\.startDate).sorted(by: >))
        XCTAssertTrue(snapshot.recent.allSatisfy { $0.averageHeartRate == nil })
    }

    func testSnapshotSeasonIsThisTermOrTheLastOnePlayed() {
        let spring = digest(-150, us: 0, them: 4), fall = digest(0, us: 2, them: 2)
        let now = WidgetSnapshot.make(from: [spring, fall], now: base)
        XCTAssertEqual(now.season?.title, "Fall 2026")
        XCTAssertEqual(now.season?.form, [.drawn])
        // January, before the first spring match.
        let between = WidgetSnapshot.make(from: [spring, fall], now: base.addingTimeInterval(120 * 86_400))
        XCTAssertEqual(between.season?.title, "Fall 2026")
    }

    func testFormIsTheLastFiveOldestFirst() {
        let results = [(1, 0), (0, 0), (0, 1), (2, 0), (3, 0), (0, 2)]
        let digests = results.enumerated().map { digest($0.offset, us: $0.element.0, them: $0.element.1) }
        let season = WidgetSnapshot.make(from: digests.reversed(), now: base).season
        XCTAssertEqual(season?.form, [.drawn, .lost, .won, .won, .lost])
    }

    func testSpokenAnswers() {
        var match = digest(0, us: 1, them: 3, distance: 7403)
        match.opponent = "Rovers"
        let snapshot = WidgetSnapshot.make(from: [match], units: .imperial, now: base)
        XCTAssertTrue(snapshot.spokenLastMatch.hasPrefix("You lost 3 to 1 against Rovers on "))
        XCTAssertTrue(snapshot.spokenLastMatch.contains("4.6 miles in 90 minutes"))
        XCTAssertEqual(snapshot.spokenSeason, "Fall 2026: 0 won, 0 drawn, 1 lost. You've covered 4.6 miles.")
    }

    func testMatchesWithoutAScoreAreCountedButNotInTheRecord() {
        let snapshot = WidgetSnapshot.make(from: [digest(0, us: 1, them: 0), digest(1)], units: .metric, now: base)
        XCTAssertTrue(snapshot.spokenSeason.contains("1 won, 0 drawn, 0 lost. 2 matches in all."))
    }

    func testSaveReportsOnlyRealChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grid = HeatmapGrid(columns: 60, rows: 40, cells: (0..<2400).map { Double($0) / 2400 })
        var snapshot = WidgetSnapshot.make(from: [digest(0, us: 1, them: 0)], heat: grid, now: base)
        XCTAssertEqual(snapshot.heat?.cells.count, 600)
        XCTAssertEqual(snapshot.heat?.cells.max(), 1)
        XCTAssertTrue(try snapshot.save(to: directory))
        XCTAssertFalse(try snapshot.save(to: directory))
        XCTAssertEqual(WidgetSnapshot.load(from: directory)?.lastMatch, snapshot.lastMatch)
        snapshot.headline = "A hat-trick."
        XCTAssertTrue(try snapshot.save(to: directory))
    }
}
