import XCTest
@testable import MatchTrackerKit

final class UnitsTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    func testRegionConvention() {
        XCTAssertEqual(UnitSystem.preferred(for: us), .imperial)
        XCTAssertEqual(UnitSystem.preferred(for: Locale(identifier: "en_GB")), .imperial)
        XCTAssertEqual(UnitSystem.preferred(for: Locale(identifier: "de_DE")), .metric)
    }

    func testImperial() {
        XCTAssertEqual(UnitSystem.imperial.distance(4345.2, locale: us).text, "2.70 mi")
        XCTAssertEqual(UnitSystem.imperial.speed(8, locale: us).text, "17.9 mph")
        XCTAssertEqual(UnitSystem.imperial.shortDistance(105, locale: us).text, "115 yd")
    }

    func testMetricUsesTheLocaleDecimalSeparator() {
        XCTAssertEqual(UnitSystem.metric.distance(4345.2, locale: Locale(identifier: "de_DE")).text, "4,35 km")
        XCTAssertEqual(UnitSystem.metric.speed(8, locale: us).text, "28.8 km/h")
    }

    func testFormatFollowsTheWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let wednesday = Date(timeIntervalSince1970: 1_792_500_000)
        let saturday = wednesday.addingTimeInterval(3 * 86_400)
        var history = FormatHistory()
        XCTAssertEqual(history.predicted(on: wednesday, calendar: calendar), .match)
        history.record(.indoor, on: wednesday, calendar: calendar)
        history.record(.match, on: saturday, calendar: calendar)
        XCTAssertEqual(history.predicted(on: wednesday.addingTimeInterval(7 * 86_400), calendar: calendar), .indoor)
        XCTAssertEqual(history.predicted(on: saturday.addingTimeInterval(86_400), calendar: calendar), .match)
    }
}
