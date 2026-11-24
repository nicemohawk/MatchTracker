import XCTest
@testable import MatchTrackerKit

final class RouteJournalTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fix(_ seconds: TimeInterval, accuracy: Double = 5) -> RouteFix {
        RouteFix(point: TrackPoint(coordinate: Coordinate2D(latitude: 39, longitude: -82),
                                   timestamp: start.addingTimeInterval(seconds),
                                   speedMetersPerSecond: 2, courseDegrees: 90,
                                   horizontalAccuracy: accuracy),
                 altitude: 210, verticalAccuracy: 4)
    }

    // MARK: Journal

    func testFixesSurviveANewProcessAndKeepAppending() throws {
        let matchID = UUID()
        try RouteJournal(directory: directory, matchID: matchID).append([fix(0), fix(1.25)])
        // A relaunch opens the same file with a fresh instance.
        let relaunched = RouteJournal(directory: directory, matchID: matchID)
        try relaunched.append([fix(90)])
        XCTAssertEqual(relaunched.load(), [fix(0), fix(1.25), fix(90)])
    }

    func testTornLastLineCostsOnlyItself() throws {
        let matchID = UUID()
        try RouteJournal(directory: directory, matchID: matchID).append([fix(0), fix(1)])
        let url = directory.appendingPathComponent("route-\(matchID.uuidString).jsonl")
        let intact = try Data(contentsOf: url)
        try intact.dropLast(20).write(to: url)   // killed mid-write of the second fix

        let relaunched = RouteJournal(directory: directory, matchID: matchID)
        try relaunched.append([fix(2)])
        XCTAssertEqual(relaunched.load(), [fix(0), fix(2)])
    }

    func testMatchesDoNotShareAJournal() throws {
        try RouteJournal(directory: directory, matchID: UUID()).append([fix(0)])
        XCTAssertTrue(RouteJournal(directory: directory, matchID: UUID()).load().isEmpty)
    }

    func testRemoveDeletesTheFile() throws {
        let journal = RouteJournal(directory: directory, matchID: UUID())
        try journal.append([fix(0)])
        journal.remove()
        XCTAssertTrue(journal.load().isEmpty)
    }

    // MARK: Filter

    func testFilterDropsStaleInvalidAndInaccurateFixes() {
        let accepted = RouteFixFilter.accept(
            [fix(-158), fix(0), fix(1, accuracy: -1), fix(2, accuracy: 51), fix(3, accuracy: 50)],
            start: start, lastAccepted: nil)
        XCTAssertEqual(accepted, [fix(0), fix(3, accuracy: 50)])
    }

    func testFilterDropsReplaysAfterARestart() {
        let accepted = RouteFixFilter.accept([fix(9), fix(10), fix(11), fix(11)],
                                             start: start, lastAccepted: start.addingTimeInterval(10))
        XCTAssertEqual(accepted, [fix(11)])
    }

    // MARK: Signal

    func testSignalLifecycle() {
        var monitor = GPSSignalMonitor(startedAt: start)
        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(60)), .acquiring)
        monitor.recordCallback(at: start.addingTimeInterval(60), usable: true)
        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(70)), .good)
        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(76)), .lost)
    }

    func testRetriesBackOffAndNeverStop() {
        var monitor = GPSSignalMonitor(startedAt: start)
        var retries: [TimeInterval] = []
        for second in stride(from: 0.0, through: 600, by: 1) {
            let now = start.addingTimeInterval(second)
            if monitor.shouldRetry(at: now) {
                monitor.recordRetry(at: now)
                retries.append(second)
            }
        }
        XCTAssertEqual(retries, [20, 60, 140, 260, 380, 500])
    }

    func testInaccurateFixesDoNotTriggerARestart() {
        var monitor = GPSSignalMonitor(startedAt: start)
        for second in stride(from: 0.0, through: 120, by: 1) {
            let now = start.addingTimeInterval(second)
            monitor.recordCallback(at: now, usable: false)
            XCTAssertFalse(monitor.shouldRetry(at: now))
        }
        XCTAssertEqual(monitor.signal(at: start.addingTimeInterval(120)), .acquiring)
    }

    func testBecomingActiveSkipsTheBackoff() {
        var monitor = GPSSignalMonitor(startedAt: start)
        monitor.recordRetry(at: start.addingTimeInterval(20))
        let now = start.addingTimeInterval(25)
        XCTAssertFalse(monitor.shouldRetry(at: now))
        XCTAssertTrue(monitor.shouldRetry(at: now, force: true))
    }
}
