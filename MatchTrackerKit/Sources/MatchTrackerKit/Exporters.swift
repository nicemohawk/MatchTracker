import Foundation

// MARK: - What gets exported

/// One match, ready for any activity file format. Half-time is left out: each period becomes a lap
/// (or a GPX track segment), and the gap between them stays a gap.
public struct ActivityExport: Sendable {
    public var name: String
    public var startDate: Date
    public var endDate: Date
    public var track: [TrackPoint]
    public var heartRate: [HeartRateSample]
    public var events: [MatchEvent]
    public var activeEnergyKilocalories: Double?

    public init(name: String, startDate: Date, endDate: Date, track: [TrackPoint],
                heartRate: [HeartRateSample] = [], events: [MatchEvent] = [],
                activeEnergyKilocalories: Double? = nil) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.track = track.sorted { $0.timestamp < $1.timestamp }
        self.heartRate = heartRate.sorted { $0.date < $1.date }
        self.events = events
        self.activeEnergyKilocalories = activeEnergyKilocalories
    }

    /// Whether there is anything a training site could show.
    public var isEmpty: Bool { track.isEmpty && heartRate.isEmpty }

    /// A heart-rate reading further away than this says nothing about a fix.
    private static let heartRateTolerance: TimeInterval = 5
    /// Steps faster than anyone runs are GPS jumping, not distance.
    private static let fastestPlausibleSpeed = 12.0

    struct Sample {
        var date: Date
        var coordinate: Coordinate2D?
        var speed: Double?
        var bpm: Int?
        /// Meters covered since the match began, breaks excluded.
        var distance: Double?
    }

    struct Lap {
        var interval: DateInterval
        var samples: [Sample]
        var distance: Double?
        var averageBPM: Int?
        var maximumBPM: Int?
        var maximumSpeed: Double?
        var kilocalories: Double?
    }

    var laps: [Lap] {
        let periods = MatchPeriods.derive(events: events, matchStart: startDate, matchEnd: endDate)
        let playSeconds = periods.reduce(0) { $0 + $1.duration }
        var covered = 0.0
        return periods.map { period in
            let points = track.filter { period.contains($0.timestamp) }
            let readings = heartRate.filter { period.contains($0.date) }
            let startDistance = covered
            var samples: [Sample] = []
            if points.isEmpty {
                // Indoors there is no route, but heart rate alone is still an activity.
                samples = readings.map { Sample(date: $0.date, bpm: Int($0.bpm.rounded())) }
            }
            for (index, point) in points.enumerated() {
                if index > 0 {
                    let previous = points[index - 1]
                    let step = haversineMeters(previous.coordinate, point.coordinate)
                    let elapsed = point.timestamp.timeIntervalSince(previous.timestamp)
                    if elapsed > 0, step / elapsed <= Self.fastestPlausibleSpeed { covered += step }
                }
                let speed = point.speedMetersPerSecond
                samples.append(Sample(
                    date: point.timestamp, coordinate: point.coordinate,
                    speed: (0...Self.fastestPlausibleSpeed).contains(speed) ? speed : nil,
                    bpm: beats(nearest: point.timestamp), distance: covered
                ))
            }
            let bpms = readings.map(\.bpm)
            return Lap(
                interval: period, samples: samples,
                distance: points.isEmpty ? nil : covered - startDistance,
                averageBPM: bpms.isEmpty ? nil : Int((bpms.reduce(0, +) / Double(bpms.count)).rounded()),
                maximumBPM: bpms.max().map { Int($0.rounded()) },
                maximumSpeed: samples.compactMap(\.speed).max(),
                kilocalories: playSeconds > 0
                    ? activeEnergyKilocalories.map { $0 * period.duration / playSeconds } : nil
            )
        }
    }

    private func beats(nearest date: Date) -> Int? {
        guard !heartRate.isEmpty else { return nil }
        var low = 0, high = heartRate.count
        while low < high {
            let middle = (low + high) / 2
            if heartRate[middle].date < date { low = middle + 1 } else { high = middle }
        }
        let nearest = [low - 1, low].filter(heartRate.indices.contains).map { heartRate[$0] }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        guard let nearest, abs(nearest.date.timeIntervalSince(date)) <= Self.heartRateTolerance else { return nil }
        return Int(nearest.bpm.rounded())
    }
}

// MARK: - Exporters

/// Serializes a match to portable file formats: FIT, TCX and GPX for training sites, CSV for
/// spreadsheets. Output is deterministic — stable number formatting, ISO8601 timestamps, and a
/// fixed ordering — so exports diff cleanly and can be golden-tested.
public enum MatchExporter {

    // MARK: GPX 1.1

    /// Fixes further apart than this start a new segment, so a gap isn't drawn as a straight line.
    private static let gpxSegmentGap: TimeInterval = 30

    /// A GPX 1.1 document: one soccer `<trk>`, at least one `<trkseg>` per period, heart rate in
    /// Garmin's trackpoint extension, and one `<wpt>` per event at the fix nearest its time.
    public static func gpx(_ activity: ActivityExport) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<gpx version="1.1" creator="MatchTracker" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">"#)
        lines.append("<metadata><name>\(xmlEscape(activity.name))</name><time>\(iso(activity.startDate))</time></metadata>")

        // Waypoints precede the track per the GPX 1.1 schema ordering.
        if !activity.track.isEmpty {
            for event in sortedEvents(activity.events) {
                let coordinate = nearestCoordinate(to: event.date, in: activity.track)
                lines.append(#"<wpt lat="\#(coord(coordinate.latitude))" lon="\#(coord(coordinate.longitude))">"#)
                lines.append("<time>\(iso(event.date))</time>")
                lines.append("<name>\(xmlEscape(event.kind.rawValue))</name>")
                if let note = event.note, !note.isEmpty {
                    lines.append("<desc>\(xmlEscape(note))</desc>")
                }
                lines.append("</wpt>")
            }
        }

        lines.append("<trk>")
        lines.append("<name>\(xmlEscape(activity.name))</name>")
        lines.append("<type>soccer</type>")
        for lap in activity.laps {
            var previousDate: Date?
            for sample in lap.samples {
                guard let coordinate = sample.coordinate else { continue }
                if let previous = previousDate, sample.date.timeIntervalSince(previous) > gpxSegmentGap {
                    lines.append("</trkseg>")
                    previousDate = nil
                }
                if previousDate == nil { lines.append("<trkseg>") }
                previousDate = sample.date
                lines.append(#"<trkpt lat="\#(coord(coordinate.latitude))" lon="\#(coord(coordinate.longitude))">"#)
                lines.append("<time>\(iso(sample.date))</time>")
                if let bpm = sample.bpm {
                    lines.append("<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(bpm)</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>")
                }
                lines.append("</trkpt>")
            }
            if previousDate != nil { lines.append("</trkseg>") }
        }
        lines.append("</trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: TCX

    /// A Garmin Training Center document with a lap per period. The format only knows running,
    /// biking and other, so soccer is `Other`; heart-rate-only (indoor) matches are valid too.
    public static func tcx(_ activity: ActivityExport) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">"#)
        lines.append("<Activities>")
        lines.append(#"<Activity Sport="Other">"#)
        lines.append("<Id>\(iso(activity.startDate))</Id>")
        for lap in activity.laps {
            lines.append(#"<Lap StartTime="\#(iso(lap.interval.start))">"#)
            lines.append("<TotalTimeSeconds>\(tenths(lap.interval.duration))</TotalTimeSeconds>")
            // The schema requires distance and calories, so an unknown one has to be written as 0.
            lines.append("<DistanceMeters>\(tenths(lap.distance ?? 0))</DistanceMeters>")
            if let speed = lap.maximumSpeed { lines.append("<MaximumSpeed>\(measure(speed))</MaximumSpeed>") }
            lines.append("<Calories>\(Int((lap.kilocalories ?? 0).rounded()))</Calories>")
            if let bpm = lap.averageBPM {
                lines.append("<AverageHeartRateBpm><Value>\(bpm)</Value></AverageHeartRateBpm>")
            }
            if let bpm = lap.maximumBPM {
                lines.append("<MaximumHeartRateBpm><Value>\(bpm)</Value></MaximumHeartRateBpm>")
            }
            lines.append("<Intensity>Active</Intensity>")
            lines.append("<TriggerMethod>Manual</TriggerMethod>")
            if !lap.samples.isEmpty {
                lines.append("<Track>")
                for sample in lap.samples {
                    lines.append("<Trackpoint>")
                    lines.append("<Time>\(iso(sample.date))</Time>")
                    if let coordinate = sample.coordinate {
                        lines.append("<Position><LatitudeDegrees>\(coord(coordinate.latitude))</LatitudeDegrees><LongitudeDegrees>\(coord(coordinate.longitude))</LongitudeDegrees></Position>")
                    }
                    if let distance = sample.distance {
                        lines.append("<DistanceMeters>\(tenths(distance))</DistanceMeters>")
                    }
                    if let bpm = sample.bpm { lines.append("<HeartRateBpm><Value>\(bpm)</Value></HeartRateBpm>") }
                    lines.append("</Trackpoint>")
                }
                lines.append("</Track>")
            }
            lines.append("</Lap>")
        }
        lines.append("<Notes>\(xmlEscape(activity.name))</Notes>")
        lines.append("</Activity>")
        lines.append("</Activities>")
        lines.append("</TrainingCenterDatabase>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: FIT

    /// A FIT activity file: soccer, a lap per period, the timer stopped between them.
    public static func fit(_ activity: ActivityExport, timeZone: TimeZone = .current) -> Data {
        FITEncoder.activity(activity, timeZone: timeZone)
    }

    // MARK: CSV

    /// One row per track point: `timestamp,latitude,longitude,speed_mps,course_deg,horizontal_accuracy_m`.
    public static func csv(track: [TrackPoint]) -> String {
        var lines = ["timestamp,latitude,longitude,speed_mps,course_deg,horizontal_accuracy_m"]
        for point in track {
            lines.append([
                iso(point.timestamp),
                coord(point.coordinate.latitude),
                coord(point.coordinate.longitude),
                measure(point.speedMetersPerSecond),
                measure(point.courseDegrees),
                measure(point.horizontalAccuracy)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One row per event: `id,kind,date,note,source`. Events are ordered by date then id.
    public static func eventsCSV(events: [MatchEvent]) -> String {
        var lines = ["id,kind,date,note,source"]
        for event in sortedEvents(events) {
            lines.append([
                event.id.uuidString,
                event.kind.rawValue,
                iso(event.date),
                csvEscape(event.note ?? ""),
                event.source.rawValue
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatting helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// Coordinates to 6 decimal places (~0.1 m), the practical limit of consumer GPS.
    private static func coord(_ value: Double) -> String { String(format: "%.6f", value) }

    private static func tenths(_ value: Double) -> String { String(format: "%.1f", value) }

    /// Speeds/courses/accuracies to 2 decimal places; invalid sentinels (-1) pass through.
    private static func measure(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func sortedEvents(_ events: [MatchEvent]) -> [MatchEvent] {
        events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// The coordinate of the track point closest in time to `date`; origin when the track is empty.
    private static func nearestCoordinate(to date: Date, in track: [TrackPoint]) -> Coordinate2D {
        guard let nearest = track.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }) else {
            return Coordinate2D(latitude: 0, longitude: 0)
        }
        return nearest.coordinate
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func csvEscape(_ string: String) -> String {
        guard string.contains(",") || string.contains("\"") || string.contains("\n") else { return string }
        let escaped = string.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// MARK: - FIT

/// Writes the Flexible and Interoperable Data Transfer (FIT) activity file format, protocol 2.0:
/// little-endian messages, each kind described once by a definition, framed by a header and CRC-16.
enum FITEncoder {
    private enum BaseType: UInt8 {
        case enumeration = 0x00, uint8 = 0x02, string = 0x07
        case uint16 = 0x84, sint32 = 0x85, uint32 = 0x86

        /// Every type reserves a value meaning "not recorded".
        var invalid: UInt32 {
            switch self {
            case .enumeration, .uint8: return 0xFF
            case .uint16: return 0xFFFF
            case .sint32: return 0x7FFF_FFFF
            case .uint32: return 0xFFFF_FFFF
            case .string: return 0
            }
        }

        var size: Int {
            switch self {
            case .enumeration, .uint8, .string: return 1
            case .uint16: return 2
            case .sint32, .uint32: return 4
            }
        }
    }

    private struct Field {
        var number: UInt8
        var type: BaseType
        var value: UInt32?
        var text: String?

        init(_ number: UInt8, _ type: BaseType, _ value: UInt32?) {
            self.number = number
            self.type = type
            self.value = value
        }

        init(_ number: UInt8, text: String) {
            self.number = number
            self.type = .string
            self.text = text
        }

        var bytes: [UInt8] {
            if let text { return Array(text.utf8) + [0] }
            let raw = value ?? type.invalid
            return (0..<type.size).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt32($0))) }
        }
    }

    private enum Message: UInt16 {
        case fileID = 0, session = 18, lap = 19, record = 20, event = 21, activity = 34
        /// Which of the 16 local definitions this kind occupies; each kind keeps its own.
        var localNumber: UInt8 {
            switch self {
            case .fileID: return 0
            case .event: return 1
            case .record: return 2
            case .lap: return 3
            case .session: return 4
            case .activity: return 5
            }
        }
    }

    private struct Body {
        private(set) var data = Data()
        private var defined: Set<UInt8> = []

        mutating func append(_ message: Message, _ fields: [Field]) {
            let local = message.localNumber
            if defined.insert(local).inserted {
                data.append(contentsOf: [0x40 | local, 0, 0])   // reserved, little-endian
                data.append(contentsOf: [UInt8(message.rawValue & 0xFF), UInt8(message.rawValue >> 8)])
                data.append(UInt8(fields.count))
                for field in fields {
                    data.append(contentsOf: [field.number, UInt8(field.bytes.count), field.type.rawValue])
                }
            }
            data.append(local)
            for field in fields { data.append(contentsOf: field.bytes) }
        }
    }

    private static let soccer: UInt32 = 7
    /// Garmin's id for files from makers without an assigned one. Claiming a real maker would be a lie.
    private static let developmentManufacturer: UInt32 = 255

    static func activity(_ activity: ActivityExport, timeZone: TimeZone) -> Data {
        var body = Body()
        let laps = activity.laps
        let start = stamp(activity.startDate), end = stamp(activity.endDate)
        body.append(.fileID, [
            Field(0, .enumeration, 4),   // activity
            Field(1, .uint16, developmentManufacturer),
            Field(2, .uint16, 1),
            Field(4, .uint32, start),
            Field(8, text: "MatchTracker")
        ])

        for (index, lap) in laps.enumerated() {
            appendTimerEvent(to: &body, date: lap.interval.start, starts: true)
            var previous: UInt32?
            for sample in lap.samples {
                // Records are whole seconds; two in the same one would break readers.
                let time = stamp(sample.date)
                guard time != previous else { continue }
                previous = time
                body.append(.record, [
                    Field(253, .uint32, time),
                    Field(0, .sint32, sample.coordinate.map { semicircles($0.latitude) }),
                    Field(1, .sint32, sample.coordinate.map { semicircles($0.longitude) }),
                    Field(5, .uint32, scaled(sample.distance, 100)),
                    Field(6, .uint16, scaled(sample.speed, 1000)),
                    Field(3, .uint8, beats(sample.bpm))
                ])
            }
            appendTimerEvent(to: &body, date: lap.interval.end, starts: false)
            body.append(.lap, [
                Field(254, .uint16, UInt32(index)),
                Field(253, .uint32, stamp(lap.interval.end)),
                Field(0, .enumeration, 9),   // lap
                Field(1, .enumeration, 1),   // stop
                Field(2, .uint32, stamp(lap.interval.start)),
                Field(7, .uint32, scaled(lap.interval.duration, 1000)),
                Field(8, .uint32, scaled(lap.interval.duration, 1000)),
                Field(9, .uint32, scaled(lap.distance, 100)),
                Field(11, .uint16, scaled(lap.kilocalories, 1)),
                Field(13, .uint16, scaled(lap.distance.map { $0 / max(1, lap.interval.duration) }, 1000)),
                Field(14, .uint16, scaled(lap.maximumSpeed, 1000)),
                Field(15, .uint8, beats(lap.averageBPM)),
                Field(16, .uint8, beats(lap.maximumBPM)),
                Field(23, .enumeration, 0),  // active
                Field(24, .enumeration, 0),  // manual
                Field(25, .enumeration, soccer)
            ])
        }

        let timer = laps.reduce(0) { $0 + $1.interval.duration }
        let distances = laps.compactMap(\.distance)
        let distance = distances.isEmpty ? nil : distances.reduce(0, +)
        let beating = laps.filter { $0.averageBPM != nil }
        let beatingSeconds = beating.reduce(0) { $0 + $1.interval.duration }
        let averageBPM = beatingSeconds > 0
            ? Int((beating.reduce(0) { $0 + Double($1.averageBPM ?? 0) * $1.interval.duration } / beatingSeconds).rounded())
            : nil
        let origin = activity.track.first?.coordinate
        body.append(.session, [
            Field(254, .uint16, 0),
            Field(253, .uint32, end),
            Field(0, .enumeration, 8),   // session
            Field(1, .enumeration, 1),   // stop
            Field(2, .uint32, start),
            Field(3, .sint32, origin.map { semicircles($0.latitude) }),
            Field(4, .sint32, origin.map { semicircles($0.longitude) }),
            Field(5, .enumeration, soccer),
            Field(6, .enumeration, 0),   // generic
            Field(7, .uint32, scaled(activity.endDate.timeIntervalSince(activity.startDate), 1000)),
            Field(8, .uint32, scaled(timer, 1000)),
            Field(9, .uint32, scaled(distance, 100)),
            Field(11, .uint16, scaled(activity.activeEnergyKilocalories, 1)),
            Field(14, .uint16, scaled(distance.map { $0 / max(1, timer) }, 1000)),
            Field(15, .uint16, scaled(laps.compactMap(\.maximumSpeed).max(), 1000)),
            Field(16, .uint8, beats(averageBPM)),
            Field(17, .uint8, beats(laps.compactMap(\.maximumBPM).max())),
            Field(25, .uint16, 0),
            Field(26, .uint16, UInt32(laps.count)),
            Field(28, .enumeration, 0)   // activity end
        ])
        let offset = Int64(timeZone.secondsFromGMT(for: activity.endDate))
        body.append(.activity, [
            Field(253, .uint32, end),
            Field(0, .uint32, scaled(timer, 1000)),
            Field(1, .uint16, 1),
            Field(2, .enumeration, 0),   // manual
            Field(3, .enumeration, 26),  // activity
            Field(4, .enumeration, 1),   // stop
            Field(5, .uint32, UInt32(clamping: Int64(end) + offset))
        ])
        return framed(body.data)
    }

    private static func appendTimerEvent(to body: inout Body, date: Date, starts: Bool) {
        body.append(.event, [
            Field(253, .uint32, stamp(date)),
            Field(0, .enumeration, 0),               // timer
            Field(1, .enumeration, starts ? 0 : 4)   // start / stop all
        ])
    }

    private static func framed(_ body: Data) -> Data {
        var file = Data([14, 0x20])                  // header size, protocol 2.0
        append16(2132, to: &file)                    // profile 21.32
        let size = UInt32(body.count)
        file.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * UInt32($0))) })
        file.append(contentsOf: Array(".FIT".utf8))
        append16(crc(file), to: &file)
        file.append(body)
        append16(crc(file), to: &file)
        return file
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// The FIT CRC-16 (reflected 0x8005, i.e. CRC-16/ARC), a nibble at a time as the SDK does it.
    static func crc(_ data: Data) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        return data.reduce(UInt16(0)) { crc, byte in
            var crc = crc
            for nibble in [byte & 0xF, byte >> 4] {
                crc = (crc >> 4) ^ table[Int(crc & 0xF)] ^ table[Int(nibble)]
            }
            return crc
        }
    }

    /// Seconds since FIT's epoch, 1989-12-31 00:00 UTC.
    private static func stamp(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970.rounded(.down)) - 631_065_600)
    }

    private static func semicircles(_ degrees: Double) -> UInt32 {
        UInt32(bitPattern: Int32(clamping: Int64((degrees * 2_147_483_648 / 180).rounded())))
    }

    private static func scaled(_ value: Double?, _ scale: Double) -> UInt32? {
        value.map { UInt32(clamping: Int64(($0 * scale).rounded())) }
    }

    private static func beats(_ bpm: Int?) -> UInt32? { bpm.map { UInt32(clamping: $0) } }
}
