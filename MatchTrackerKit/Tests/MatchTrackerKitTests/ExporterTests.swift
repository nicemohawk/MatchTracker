import XCTest
@testable import MatchTrackerKit

final class ExporterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ seconds: Double, latitude: Double, speed: Double = 2) -> TrackPoint {
        TrackPoint(coordinate: Coordinate2D(latitude: latitude, longitude: -83),
                   timestamp: start.addingTimeInterval(seconds), speedMetersPerSecond: speed,
                   courseDegrees: 0, horizontalAccuracy: 5)
    }

    /// Two two-minute halves around a one-minute break spent walking about.
    private func match() -> ActivityExport {
        let track = stride(from: 0.0, through: 300, by: 10).map { point($0, latitude: 40 + $0 * 0.00001) }
        let heartRate = stride(from: 1.0, through: 300, by: 20).map {
            HeartRateSample(date: start.addingTimeInterval($0), bpm: 140 + $0 / 10)
        }
        return ActivityExport(
            name: "Match v Rovers & Sons", startDate: start, endDate: start.addingTimeInterval(300),
            track: track, heartRate: heartRate,
            halftime: DateInterval(start: start.addingTimeInterval(120), duration: 60),
            activeEnergyKilocalories: 80
        )
    }

    // MARK: Laps

    func testLapsLeaveOutTheBreakAndKeepDistanceRunning() {
        let laps = match().laps
        XCTAssertEqual(laps.count, 2)
        XCTAssertEqual(laps.map(\.interval.duration), [120, 120])
        XCTAssertEqual(laps[0].kilocalories, 40)
        XCTAssertFalse(laps.flatMap(\.samples).contains {
            (121..<180).contains($0.date.timeIntervalSince(start))
        })
        // Fixes ten seconds apart are measured straight: 0.0001 degrees of latitude is 11.1 m.
        XCTAssertEqual(laps[0].distance ?? 0, 133.4, accuracy: 0.5)
        XCTAssertEqual(laps[1].samples.last?.distance ?? 0, 266.9, accuracy: 1)
    }

    func testDistanceIsTheMatchsOwn() {
        var activity = match()
        // The route measures 333.6 m in all, break included; the match's one distance is half that.
        activity.distanceMeters = 166.8
        XCTAssertEqual(activity.laps.compactMap(\.distance).reduce(0, +), 133.4, accuracy: 1)
    }

    func testHeartRateIsBoundOnlyWhenClose() {
        var activity = match()
        activity.heartRate = [HeartRateSample(date: start.addingTimeInterval(4), bpm: 150)]
        let samples = activity.laps[0].samples
        XCTAssertEqual(samples[0].bpm, 150)
        XCTAssertNil(samples[1].bpm, "six seconds away is not a reading for this fix")
    }

    func testTeleportsAreNotDistance() {
        let activity = ActivityExport(
            name: "Jump", startDate: start, endDate: start.addingTimeInterval(120),
            track: [point(0, latitude: 40), point(1, latitude: 40.01, speed: 1100), point(2, latitude: 40.01001, speed: 1.1)])
        XCTAssertEqual(activity.laps[0].distance ?? 0, 1.1, accuracy: 0.1)
    }

    // MARK: GPX

    func testGPXNamesTheSportAndSplitsTheHalves() throws {
        let gpx = MatchExporter.gpx(match())
        XCTAssertEqual(try rootElement(of: gpx), "gpx")
        XCTAssertTrue(gpx.contains("<type>soccer</type>"))
        XCTAssertTrue(gpx.contains("<name>Match v Rovers &amp; Sons</name>"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertEqual(gpx.components(separatedBy: "</trkseg>").count - 1, 2)
        XCTAssertTrue(gpx.contains("<gpxtpx:hr>140</gpxtpx:hr>"))
    }

    func testGPXStartsANewSegmentAfterAGap() {
        let activity = ActivityExport(
            name: "Gap", startDate: start, endDate: start.addingTimeInterval(120),
            track: [point(0, latitude: 40), point(10, latitude: 40), point(60, latitude: 40)])
        XCTAssertEqual(MatchExporter.gpx(activity).components(separatedBy: "<trkseg>").count - 1, 2)
    }

    // MARK: TCX

    func testTCXGolden() throws {
        let activity = ActivityExport(
            name: "Match", startDate: start, endDate: start.addingTimeInterval(120),
            track: [point(0, latitude: 40, speed: 1.5), point(10, latitude: 40.0001, speed: 3.25)],
            heartRate: [HeartRateSample(date: start, bpm: 120), HeartRateSample(date: start.addingTimeInterval(9), bpm: 131)],
            activeEnergyKilocalories: 20)
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
        <Activities>
        <Activity Sport="Other">
        <Id>2023-11-14T22:13:20Z</Id>
        <Lap StartTime="2023-11-14T22:13:20Z">
        <TotalTimeSeconds>120.0</TotalTimeSeconds>
        <DistanceMeters>11.1</DistanceMeters>
        <MaximumSpeed>3.25</MaximumSpeed>
        <Calories>20</Calories>
        <AverageHeartRateBpm><Value>126</Value></AverageHeartRateBpm>
        <MaximumHeartRateBpm><Value>131</Value></MaximumHeartRateBpm>
        <Intensity>Active</Intensity>
        <TriggerMethod>Manual</TriggerMethod>
        <Track>
        <Trackpoint>
        <Time>2023-11-14T22:13:20Z</Time>
        <Position><LatitudeDegrees>40.000000</LatitudeDegrees><LongitudeDegrees>-83.000000</LongitudeDegrees></Position>
        <DistanceMeters>0.0</DistanceMeters>
        <HeartRateBpm><Value>120</Value></HeartRateBpm>
        </Trackpoint>
        <Trackpoint>
        <Time>2023-11-14T22:13:30Z</Time>
        <Position><LatitudeDegrees>40.000100</LatitudeDegrees><LongitudeDegrees>-83.000000</LongitudeDegrees></Position>
        <DistanceMeters>11.1</DistanceMeters>
        <HeartRateBpm><Value>131</Value></HeartRateBpm>
        </Trackpoint>
        </Track>
        </Lap>
        <Notes>Match</Notes>
        </Activity>
        </Activities>
        </TrainingCenterDatabase>

        """
        XCTAssertEqual(MatchExporter.tcx(activity), expected)
        XCTAssertEqual(try rootElement(of: expected), "TrainingCenterDatabase")
    }

    func testIndoorMatchExportsHeartRateAlone() throws {
        let activity = ActivityExport(
            name: "Indoor", startDate: start, endDate: start.addingTimeInterval(120), track: [],
            heartRate: [HeartRateSample(date: start.addingTimeInterval(30), bpm: 150)])
        let tcx = MatchExporter.tcx(activity)
        XCTAssertTrue(tcx.contains("<HeartRateBpm><Value>150</Value></HeartRateBpm>"))
        XCTAssertFalse(tcx.contains("<Position>"))
        let records = try FITReader(MatchExporter.fit(activity)).messages.filter { $0.number == 20 }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].unsigned[3], 150)
        XCTAssertEqual(records[0].unsigned[0], 0x7FFF_FFFF, "no position is the invalid marker, not 0°N")
    }

    // MARK: FIT

    /// CRC-16/ARC's published check value.
    func testCRC() {
        XCTAssertEqual(FITEncoder.crc(Data("123456789".utf8)), 0xBB3D)
    }

    func testFITDecodesToASoccerMatch() throws {
        let file = MatchExporter.fit(match(), timeZone: TimeZone(secondsFromGMT: -18_000)!)
        let reader = try FITReader(file)
        let byKind = Dictionary(grouping: reader.messages, by: \.number)

        let fileID = try XCTUnwrap(byKind[0]?.first)
        XCTAssertEqual(reader.messages.first?.number, 0, "file_id comes first")
        XCTAssertEqual(fileID.unsigned[0], 4)
        XCTAssertEqual(fileID.unsigned[1], 255)
        XCTAssertEqual(fileID.unsigned[4], 1_700_000_000 - 631_065_600)

        let session = try XCTUnwrap(byKind[18]?.first)
        XCTAssertEqual(session.unsigned[5], 7, "soccer")
        XCTAssertEqual(session.unsigned[7], 300_000)
        XCTAssertEqual(session.unsigned[8], 240_000, "half-time isn't on the timer")
        XCTAssertEqual(session.unsigned[26], 2)
        XCTAssertEqual(session.unsigned[11], 80)
        XCTAssertEqual(Double(session.unsigned[9] ?? 0) / 100, 266.9, accuracy: 1)

        XCTAssertEqual(byKind[19]?.count, 2)
        XCTAssertEqual(byKind[19]?.map { $0.unsigned[25] }, [7, 7])
        XCTAssertEqual(byKind[21]?.map { $0.unsigned[1] }, [0, 4, 0, 4], "timer starts and stops each half")

        let records = try XCTUnwrap(byKind[20])
        XCTAssertEqual(records.count, 13 + 13)
        let latitude = Double(Int32(bitPattern: records[0].unsigned[0] ?? 0)) * 180 / 2_147_483_648
        XCTAssertEqual(latitude, 40, accuracy: 1e-6)
        XCTAssertEqual(records[0].unsigned[3], 140)
        XCTAssertEqual(records[0].unsigned[6], 2000)
        XCTAssertEqual(records.map { $0.unsigned[253] ?? 0 }, records.map { $0.unsigned[253] ?? 0 }.sorted())

        let activity = try XCTUnwrap(byKind[34]?.first)
        XCTAssertEqual((activity.unsigned[253] ?? 0) - (activity.unsigned[5] ?? 0), 18_000)
        XCTAssertEqual(reader.messages.last?.number, 34)
    }

    func testFITIsDeterministicAndNeverWritesTwoRecordsForOneSecond() throws {
        var activity = match()
        activity.track = [point(0, latitude: 40), point(0.4, latitude: 40), point(1, latitude: 40)]
        activity.heartRate = []
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(MatchExporter.fit(activity, timeZone: zone), MatchExporter.fit(activity, timeZone: zone))
        XCTAssertEqual(try FITReader(MatchExporter.fit(activity)).messages.filter { $0.number == 20 }.count, 2)
    }

    // MARK: Helpers

    private func rootElement(of xml: String) throws -> String {
        final class Root: NSObject, XMLParserDelegate {
            var name: String?
            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                name = name ?? element
            }
        }
        let root = Root()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = root
        XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError))")
        return try XCTUnwrap(root.name)
    }
}

/// Reads a FIT file back from the protocol description, sharing no code with the encoder.
private struct FITReader {
    struct Message {
        var number: UInt16
        var unsigned: [UInt8: UInt32]
    }

    enum Failure: Error { case header, checksum, truncated, undefinedMessage }

    private(set) var messages: [Message] = []

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        func little(_ offset: Int, _ count: Int) -> UInt32 {
            (0..<count).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        guard bytes.count > 16, bytes[0] == 14, Array(bytes[8..<12]) == Array(".FIT".utf8),
              little(4, 4) == UInt32(bytes.count - 16) else { throw Failure.header }
        guard Self.checksum(bytes[0..<12]) == UInt16(little(12, 2)),
              Self.checksum(bytes[0..<(bytes.count - 2)]) == UInt16(little(bytes.count - 2, 2)) else {
            throw Failure.checksum
        }
        var definitions: [UInt8: (number: UInt16, fields: [(number: UInt8, size: Int)])] = [:]
        var offset = 14
        while offset < bytes.count - 2 {
            let header = bytes[offset]
            offset += 1
            if header & 0x40 != 0 {
                guard bytes[offset + 1] == 0 else { throw Failure.header }
                let count = Int(bytes[offset + 4])
                let fields = (0..<count).map { index -> (number: UInt8, size: Int) in
                    (bytes[offset + 5 + index * 3], Int(bytes[offset + 6 + index * 3]))
                }
                definitions[header & 0x0F] = (UInt16(little(offset + 2, 2)), fields)
                offset += 5 + count * 3
            } else {
                guard let definition = definitions[header & 0x0F] else { throw Failure.undefinedMessage }
                var values: [UInt8: UInt32] = [:]
                for field in definition.fields {
                    guard offset + field.size <= bytes.count - 2 else { throw Failure.truncated }
                    if field.size <= 4 { values[field.number] = little(offset, field.size) }
                    offset += field.size
                }
                messages.append(Message(number: definition.number, unsigned: values))
            }
        }
    }

    /// Bitwise CRC-16/ARC, unlike the encoder's table.
    private static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        bytes.reduce(UInt16(0)) { crc, byte in
            (0..<8).reduce(crc ^ UInt16(byte)) { value, _ in
                value & 1 == 1 ? (value >> 1) ^ 0xA001 : value >> 1
            }
        }
    }
}
